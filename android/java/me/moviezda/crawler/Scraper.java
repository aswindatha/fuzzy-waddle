package me.moviezda.crawler;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * All the scraping lives here. It mirrors start-crawler.ps1:
 *   moviezda: <movie>/  ->  <collection>/  ->  <quality>/  ->  /download/<slug>/
 *            -> moviespage  ->  downloadpage  ->  fastbytes  ->  r2 CDN
 *   isaiDub : <movie>/  ->  <collection|season>/  ->  <quality>/  ->  /download/page/<id>/
 *            -> dubpage  ->  dubmv  ->  uptodub | isaidub.dad  ->  r2 / uptodub CDN
 *
 * Every request must pass allowed(); ad / popunder hosts are refused
 * before a socket is opened, which is the whole point of the app.
 */
final class Scraper {

    static final String BASE = "https://moviezda.me";
    static final String ISAI = "https://isaidub.green";
    static final String UA =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36";

    private static final Set<String> ALLOWED = new HashSet<>(Arrays.asList(
            "moviezda.me",
            "www.moviezda.me",
            "download.moviespage.xyz",
            "movies.downloadpage.xyz",
            "download.fastbytes.xyz",
            "play.onestream.today",
            "isaidub.green",
            "www.isaidub.green",
            "dubpage.xyz",
            "www.dubpage.xyz",
            "dubmv.xyz",
            "www.dubmv.xyz",
            "uptodub.ch",
            "dub.uptodub.ch",
            "isaidub.dad",
            "dubshare.one"));

    static boolean allowed(String url) {
        try {
            String h = new URL(url).getHost().toLowerCase(Locale.ROOT);
            if (ALLOWED.contains(h)) return true;
            return h.endsWith(".r2.cloudflarestorage.com")
                    || h.endsWith(".uptodub.ch")
                    || h.endsWith(".isaidub.dad")
                    || h.endsWith(".dubshare.one");
        } catch (Exception e) {
            return false;
        }
    }

    // metadata-only hosts for poster lookup - never part of the download chain
    private static final Set<String> META = new HashSet<>(Arrays.asList(
            "en.wikipedia.org",
            "upload.wikimedia.org",
            "commons.wikimedia.org",
            "api.tvmaze.com",
            "static.tvmaze.com"));

    private static boolean metaAllowed(String url) {
        try {
            return META.contains(new URL(url).getHost().toLowerCase(Locale.ROOT));
        } catch (Exception e) {
            return false;
        }
    }

    // GET a small JSON body from a metadata host; retries 429/5xx with backoff
    static String metaGet(String url) throws IOException {
        if (!metaAllowed(url)) throw new IOException("Meta host not allowed: " + url);
        IOException last = null;
        for (int a = 0; a < 3; a++) {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(12000);
                c.setReadTimeout(15000);
                c.setRequestProperty("User-Agent", UA);
                c.setRequestProperty("Accept", "application/json");
                int st = c.getResponseCode();
                if (st == 429 || st >= 500) {
                    last = new IOException("meta http " + st);
                    try { Thread.sleep(2000L * (a + 1)); } catch (InterruptedException ignored) { }
                    continue;
                }
                InputStream is = st >= 400 ? c.getErrorStream() : c.getInputStream();
                ByteArrayOutputStream bo = new ByteArrayOutputStream();
                if (is != null) {
                    byte[] buf = new byte[16384];
                    int n;
                    while ((n = is.read(buf)) > 0) bo.write(buf, 0, n);
                    is.close();
                }
                if (st != 200) return null;
                return bo.toString("UTF-8");
            } catch (IOException e) {
                last = e;
            } finally {
                if (c != null) c.disconnect();
            }
        }
        if (last != null) throw last;
        return null;
    }

    // ------------------------------------------------------------------ http

    static final class Res {
        int status;
        String location;
        String type;
        String text = "";
        long total = -1;
    }

    static Res get(String url, String range) throws IOException {
        return get(url, range, -1);
    }

    // maxBytes >= 0 caps the body read - link probes must never pull a whole
    // movie into memory even if the server ignores the Range header.
    static Res get(String url, String range, long maxBytes) throws IOException {
        if (!allowed(url)) throw new IOException("Blocked host: " + url);

        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(20000);
            c.setReadTimeout(45000);
            c.setRequestProperty("User-Agent", UA);
            c.setRequestProperty("Accept", "text/html,application/xhtml+xml,*/*;q=0.8");
            c.setRequestProperty("Accept-Language", "en-US,en;q=0.9");
            if (range != null) c.setRequestProperty("Range", "bytes=" + range);

            Res r = new Res();
            r.status = c.getResponseCode();
            r.location = c.getHeaderField("Location");
            r.type = c.getContentType();

            String cr = c.getHeaderField("Content-Range");
            if (cr != null && cr.lastIndexOf('/') > 0) {
                try { r.total = Long.parseLong(cr.substring(cr.lastIndexOf('/') + 1).trim()); }
                catch (NumberFormatException ignored) { }
            }
            if (r.total < 0) {
                String cl = c.getHeaderField("Content-Length");
                if (cl != null) { try { r.total = Long.parseLong(cl.trim()); } catch (NumberFormatException ignored) { } }
            }

            InputStream is = r.status >= 400 ? c.getErrorStream() : c.getInputStream();
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            if (is != null) {
                byte[] buf = new byte[16384];
                long got = 0;
                int n;
                while ((n = is.read(buf)) > 0) {
                    if (maxBytes >= 0 && got + n > maxBytes) {
                        bo.write(buf, 0, (int) (maxBytes - got));
                        break;
                    }
                    bo.write(buf, 0, n);
                    got += n;
                }
                is.close();
            }
            r.text = new String(bo.toByteArray(), StandardCharsets.UTF_8);
            return r;
        } finally {
            c.disconnect();
        }
    }

    // ---------------------------------------------------------------- parsing

    private static final Pattern RE_FOLDER = Pattern.compile("<div class=\"f\">(.*?)</div>", Pattern.DOTALL);
    // nav/listing pages wrap child links in <div class="folder">, but the A-Z
    // listing pages use <div class="f"> for the same job - accept both.
    private static final Pattern RE_ISAI_FOLDER = Pattern.compile("<div class=\"(?:folder|f)\">(.*?)</div>", Pattern.DOTALL);
    private static final Pattern RE_ANCHOR = Pattern.compile("<a\\b([^>]*)>(.*?)</a>", Pattern.DOTALL);
    private static final Pattern RE_HREF   = Pattern.compile("href\\s*=\\s*[\"']([^\"']*)[\"']");
    private static final Pattern RE_CLASS  = Pattern.compile("class\\s*=\\s*[\"']([^\"']*)[\"']");
    private static final Pattern RE_DETAIL = Pattern.compile("<div class=\"details\">\\s*<strong>([^<]+)</strong>\\s*(.*?)</div>", Pattern.DOTALL);
    private static final Pattern RE_H1     = Pattern.compile("<h1[^>]*>(.*?)</h1>", Pattern.DOTALL);
    private static final Pattern RE_TITLE  = Pattern.compile("<title[^>]*>(.*?)</title>", Pattern.DOTALL);
    private static final Pattern RE_TAG    = Pattern.compile("<[^>]+>");
    private static final Pattern RE_FSIZE  = Pattern.compile("File Size:\\s*([0-9][0-9.,]*\\s*[KMGT]?B)");
    private static final Pattern RE_FFMT   = Pattern.compile("Download Format:\\s*([A-Za-z0-9]+)");

    static final class Anchor {
        String href;
        String cls;
        String text;
    }

    static String unescape(String s) {
        return s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&quot;", "\"").replace("&#0?39;", "'").replace("&apos;", "'")
                .replace("&nbsp;", " ");
    }

    static String text(String html) {
        String s = RE_TAG.matcher(html).replaceAll(" ");
        s = unescape(s);
        return s.replaceAll("\\s+", " ").trim();
    }

    static List<Anchor> anchors(String html) {
        List<Anchor> out = new ArrayList<>();
        Matcher m = RE_ANCHOR.matcher(html);
        while (m.find()) {
            Anchor a = new Anchor();
            String attrs = m.group(1);
            Matcher h = RE_HREF.matcher(attrs);
            if (h.find()) a.href = unescape(h.group(1));
            Matcher c = RE_CLASS.matcher(attrs);
            if (c.find()) a.cls = c.group(1);
            a.text = text(m.group(2));
            if (a.href != null && !a.href.isEmpty() && !"#".equals(a.href)) out.add(a);
        }
        return out;
    }

    static List<Anchor> folderLinks(String html) {
        return folderLinks(html, RE_FOLDER);
    }

    static List<Anchor> isaiFolderLinks(String html) {
        // children are always /movie/... links; /download/page/ file links
        // are filtered out so they can never be mistaken for folders.
        List<Anchor> out = new ArrayList<>();
        Matcher m = RE_ISAI_FOLDER.matcher(html);
        while (m.find()) {
            for (Anchor a : anchors(m.group(1))) {
                if (a.href != null && a.href.startsWith("/movie/")) { out.add(a); break; }
            }
        }
        return out;
    }

    private static List<Anchor> folderLinks(String html, Pattern re) {
        List<Anchor> out = new ArrayList<>();
        Matcher m = re.matcher(html);
        while (m.find()) {
            for (Anchor a : anchors(m.group(1))) { out.add(a); break; }
        }
        return out;
    }

    // isaiDub quality page: each <a class="coral" href="/download/page/<id>/">
    // is one downloadable file (encode or episode). File Size / Download
    // Format sit in <li> siblings AFTER the anchor - i.e. in the text between
    // this anchor and the next coral one.
    static final class IsaiFile {
        String href = "", text = "", size = "", format = "";
    }

    static List<IsaiFile> isaiFiles(String html) {
        List<IsaiFile> out = new ArrayList<>();
        List<int[]> spans = new ArrayList<>();
        List<String> hrefs = new ArrayList<>();
        List<String> texts = new ArrayList<>();

        Matcher m = RE_ANCHOR.matcher(html);
        while (m.find()) {
            String attrs = m.group(1);
            if (attrs == null || !attrs.toLowerCase(Locale.ROOT).contains("coral")) continue;
            Matcher h = RE_HREF.matcher(attrs);
            if (!h.find()) continue;
            String href = unescape(h.group(1));
            if (href == null || !href.contains("/download/page/")) continue;
            spans.add(new int[]{m.start(), m.end()});
            hrefs.add(href);
            texts.add(text(m.group(2)));
        }

        for (int i = 0; i < spans.size(); i++) {
            int from = spans.get(i)[1];
            int to = (i + 1 < spans.size()) ? spans.get(i + 1)[0]
                    : Math.min(html.length(), from + 6000);
            int len = Math.max(0, Math.min(to - from, 5000));
            String seg = len > 0 ? text(html.substring(from, from + len)) : "";

            IsaiFile f = new IsaiFile();
            f.href = hrefs.get(i);
            f.text = texts.get(i);
            Matcher sm = RE_FSIZE.matcher(seg);
            if (sm.find()) f.size = sm.group(1).trim();
            Matcher fm = RE_FFMT.matcher(seg);
            if (fm.find()) f.format = fm.group(1).trim();
            out.add(f);
        }
        return out;
    }

    static String firstHref(String html, String hostPattern) {
        Pattern p = Pattern.compile(hostPattern);
        for (Anchor a : anchors(html)) {
            if (a.href != null && p.matcher(a.href).find()) return a.href;
        }
        return null;
    }

    static String pageTitle(String html) {
        Matcher m = RE_H1.matcher(html);
        if (m.find()) {
            String t = text(m.group(1));
            if (!t.isEmpty()) return t;
        }
        Matcher t = RE_TITLE.matcher(html);
        return t.find() ? text(t.group(1)) : "";
    }

    static String fmtQuality(String label) {
        if (label == null || label.isEmpty()) return "";
        Matcher m = Pattern.compile("\\(([^()]*)\\)\\s*$").matcher(label);
        if (m.find()) return m.group(1).trim();
        m = Pattern.compile("(?i)(\\d{3,4}p(?:\\s*(?:HD|WEB-?DL|HDRip))?)").matcher(label);
        if (m.find()) return m.group(1).trim();
        return label.trim();
    }

    // ------------------------------------------------------------------ tree

    static final class Item {
        String section = "";
        String quality = "";
        String file = "";
        String size = "";
        String format = "";
        String dpath = "";
    }

    static List<Item> tree(String path, int depth, String section, String quality) throws IOException {
        List<Item> out = new ArrayList<>();
        if (depth > 4) return out;

        String url = path.startsWith("http") ? path : BASE + path;
        Res r = get(url, null);
        if (r.status != 200) throw new IOException("HTTP " + r.status + " for " + url);

        String title = pageTitle(r.text);
        List<Anchor> folders = folderLinks(r.text);
        List<Anchor> coral = new ArrayList<>();
        for (Anchor a : anchors(r.text)) {
            if (a.cls != null && a.cls.contains("coral")) coral.add(a);
        }

        if (!coral.isEmpty()) {
            String label = quality != null && !quality.isEmpty() ? fmtQuality(quality)
                    : fmtQuality(title);
            if (label.isEmpty()) {
                Matcher m = Pattern.compile("(?i)(\\d{3,4}p)").matcher(path);
                if (m.find()) label = m.group(1).toUpperCase(Locale.ROOT);
            }
            for (Anchor c : coral) {
                Item it = new Item();
                it.section = section == null ? "" : section;
                it.quality = label;
                it.file = c.text;
                it.dpath = c.href;
                Matcher mb = Pattern.compile("\\((\\d+(?:\\.\\d+)?\\s*[MG]B)\\)").matcher(c.text);
                if (mb.find()) it.quality = label + " \u00b7 " + mb.group(1);
                out.add(it);
            }
            return out;
        }

        for (Anchor f : folders) {
            boolean isQuality = f.text.matches("(?i).*(\\(\\s*\\d{3,4}p|\\(\\s*(HD|4K)|720p|1080p|360p|480p|WEB-?DL|HDRip).*");
            List<Item> kids;
            if (isQuality) kids = tree(f.href, depth + 1, section, f.text);
            else           kids = tree(f.href, depth + 1, f.text, "");
            out.addAll(kids);
        }
        return out;
    }

    // isaiDub tree: same shape as moviezda (movie -> collection/season ->
    // quality -> files) but folders live in <div class="folder"> and files
    // are <a class="coral" href="/download/page/<id>/"> blocks.
    static List<Item> treeIsai(String path, int depth, String section, String quality) throws IOException {
        List<Item> out = new ArrayList<>();
        if (depth > 5) return out;

        String url = path.startsWith("http") ? path : ISAI + path;
        Res r = get(url, null);
        if (r.status != 200) throw new IOException("HTTP " + r.status + " for " + url);

        List<IsaiFile> files = isaiFiles(r.text);
        if (!files.isEmpty()) {
            String label = quality != null && !quality.isEmpty() ? fmtQuality(quality)
                    : fmtQuality(pageTitle(r.text));
            if (label.isEmpty()) {
                Matcher m = Pattern.compile("(?i)(\\d{3,4}p)").matcher(path);
                if (m.find()) label = m.group(1).toUpperCase(Locale.ROOT);
            }
            for (IsaiFile f : files) {
                Item it = new Item();
                it.section = section == null ? "" : section;
                it.quality = label + (f.size.isEmpty() ? "" : " · " + f.size);
                it.file = f.text;
                it.size = f.size;
                it.format = f.format;
                it.dpath = f.href;
                out.add(it);
            }
            return out;
        }

        for (Anchor f : isaiFolderLinks(r.text)) {
            boolean isQuality = f.text.matches("(?i).*(\\(\\s*\\d{3,4}p|\\(\\s*(HD|4K)|720p|1080p|360p|480p|WEB-?DL|HDRip).*");
            List<Item> kids;
            if (isQuality) kids = treeIsai(f.href, depth + 1, section, f.text);
            else           kids = treeIsai(f.href, depth + 1, f.text, "");
            out.addAll(kids);
        }
        return out;
    }

    static final class Variant {
        String file = "", size = "", resolution = "", duration = "", format = "", added = "", server = "", watch = "";
    }

    static Variant details(String dpath) throws IOException {
        return details(dpath, "moviezda");
    }

    static Variant details(String dpath, String site) throws IOException {
        boolean isai = "isaidub".equals(site);
        String base = isai ? ISAI : BASE;
        String url = dpath.startsWith("http") ? dpath : base + dpath;
        Res r = get(url, null);
        Variant v = new Variant();

        Matcher m = RE_DETAIL.matcher(r.text);
        while (m.find()) {
            String k = m.group(1).replace(":", "").trim();
            String val = text(m.group(2));
            if ("File Name".equalsIgnoreCase(k)) v.file = val;
            else if ("File Size".equalsIgnoreCase(k)) v.size = val;
            else if ("Video Resolution".equalsIgnoreCase(k) || "Video Size".equalsIgnoreCase(k)) v.resolution = val;
            else if ("Duration".equalsIgnoreCase(k)) v.duration = val;
            else if ("Download Format".equalsIgnoreCase(k) || "Format".equalsIgnoreCase(k)) v.format = val;
            else if ("Added On".equalsIgnoreCase(k)) v.added = val;
        }

        if (isai) {
            String s = firstHref(r.text, "dubpage\\.xyz/download/view/\\d+");
            if (s != null) v.server = s;
            String w = firstHref(r.text, "dub\\.onestream\\.today");
            if (w != null) v.watch = w;
        } else {
            String s = firstHref(r.text, "download\\.moviespage\\.xyz/download/file/\\d+");
            if (s != null) v.server = s;
            String w = firstHref(r.text, "onestream\\.today");
            if (w != null) v.watch = w;
        }
        return v;
    }

    // ---------------------------------------------------------------- posters
    // title -> poster image via keyless metadata sources (wikipedia / tvmaze).
    // mirrors start-crawler.ps1 Get-PosterImage; results cached per session.

    private static final Map<String, String> POSTERS = new HashMap<>();
    private static final Object POSTER_LOCK = new Object();

    static String cleanTitle(String t) {
        String s = t == null ? "" : t;
        s = s.replaceAll("\\(\\d{4}\\)", " ");
        s = s.replaceAll("\\b(19|20)\\d{2}\\b", " ");
        s = s.replaceAll("(?i)\\b(tamil|telugu|hindi|english|kannada|malayalam|dubbed|dual|audio)\\b", " ");
        s = s.replaceAll("(?i)\\b(download|isaidub|isaimini|moviezda|moviesda|isai\\s?dub|full|movie|movies|web|series|episodes?|season|hq|hdrip|bluray|web-?dl|pre-?hd|hd|fhd|4k|480p|720p|1080p)\\b", " ");
        s = s.replaceAll("[^\\w\\s&]", " ");
        return s.replaceAll("\\s+", " ").trim();
    }

    private static JSONObject wikiPage(String query) {
        try {
            String qs = URLEncoder.encode(query, "UTF-8");
            String body = metaGet("https://en.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch=" + qs
                    + "&gsrnamespace=0&gsrlimit=1&prop=pageprops|images|categories&imlimit=50&pplimit=1&cllimit=50&format=json&formatversion=2&redirects=1");
            if (body == null) return null;
            JSONObject q = new JSONObject(body).optJSONObject("query");
            if (q == null) return null;
            JSONArray pages = q.optJSONArray("pages");
            if (pages == null || pages.length() == 0) return null;
            JSONObject page = pages.getJSONObject(0);
            if (page.optBoolean("missing")) return null;
            return page;
        } catch (Exception e) { return null; }
    }

    private static boolean filmPage(JSONObject page) {
        if (page == null) return false;
        JSONArray cats = page.optJSONArray("categories");
        if (cats == null || cats.length() == 0) return true;
        for (int i = 0; i < cats.length(); i++) {
            String t;
            try { t = cats.getJSONObject(i).optString("title", ""); }
            catch (Exception e) { continue; }
            if (t.matches("(?i).*(films?$|movies?$|television|series|miniseries|web|animated|documentary|silent|short film).*")) return true;
        }
        return false;
    }

    private static String wikiSuggestion(String query) {
        try {
            String qs = URLEncoder.encode(query, "UTF-8");
            String body = metaGet("https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=" + qs
                    + "&srlimit=1&format=json&formatversion=2");
            if (body == null) return null;
            JSONObject q = new JSONObject(body).optJSONObject("query");
            if (q == null) return null;
            JSONObject si = q.optJSONObject("searchinfo");
            return si == null ? null : si.optString("suggestion", null);
        } catch (Exception e) { return null; }
    }

    private static String wikiP18(String qid) {
        try {
            String body = metaGet("https://en.wikipedia.org/w/api.php?action=wbgetentities&ids=" + qid + "&props=claims&format=json");
            if (body == null) return null;
            JSONObject ent = new JSONObject(body).optJSONObject("entities");
            if (ent == null) return null;
            JSONObject e = ent.optJSONObject(qid);
            if (e == null) return null;
            JSONObject claims = e.optJSONObject("claims");
            if (claims == null) return null;
            JSONArray p18 = claims.optJSONArray("P18");
            if (p18 == null || p18.length() == 0) return null;
            JSONObject snak = p18.getJSONObject(0).optJSONObject("mainsnak");
            if (snak == null) return null;
            JSONObject dv = snak.optJSONObject("datavalue");
            if (dv == null) return null;
            String v = dv.optString("value", "");
            if (v.startsWith("File:")) v = v.substring(5);
            return v.isEmpty() ? null : v;
        } catch (Exception e) { return null; }
    }

    private static String fileThumb(String fileName) {
        try {
            String fn = URLEncoder.encode("File:" + fileName, "UTF-8");
            String body = metaGet("https://en.wikipedia.org/w/api.php?action=query&titles=" + fn
                    + "&prop=imageinfo&iiprop=url&iiurlwidth=480&format=json&formatversion=2");
            if (body == null) return null;
            JSONObject q = new JSONObject(body).optJSONObject("query");
            if (q == null) return null;
            JSONArray pages = q.optJSONArray("pages");
            if (pages == null || pages.length() == 0) return null;
            JSONArray info = pages.getJSONObject(0).optJSONArray("imageinfo");
            if (info == null || info.length() == 0) return null;
            JSONObject i0 = info.getJSONObject(0);
            String u = i0.optString("thumburl", null);
            if (u == null) u = i0.optString("url", null);
            return u;
        } catch (Exception e) { return null; }
    }

    private static List<String> titleTokens(String clean) {
        List<String> out = new ArrayList<>();
        for (String w : clean.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", " ").trim().split("\\s+")) {
            if (w.length() >= 2 || w.matches("\\d+")) out.add(w);
        }
        return out;
    }

    private static String normFileName(String s) {
        return s.toLowerCase(Locale.ROOT)
                .replaceAll("(?<=\\w)\\.(?=\\w)", "")
                .replaceAll("[^a-z0-9]+", " ")
                .trim();
    }

    private static String posterWiki(String title) {
        Matcher ym = Pattern.compile("\\b(19\\d{2}|20\\d{2})\\b").matcher(title);
        String year = ym.find() ? ym.group() : "";
        String clean = cleanTitle(title);
        if (clean.isEmpty()) return null;
        String query = clean + (year.isEmpty() ? "" : " " + year);

        JSONObject page = wikiPage(query);
        if (!filmPage(page)) {
            String sug = wikiSuggestion(query);
            JSONObject p2 = sug == null ? null : wikiPage(sug);
            page = filmPage(p2) ? p2 : null;
        }
        if (page == null) return null;

        // 1) authoritative poster: wikidata P18 (the infobox image)
        JSONObject pp = page.optJSONObject("pageprops");
        String qid = pp == null ? null : pp.optString("wikibase_item", null);
        if (qid != null) {
            String f = wikiP18(qid);
            if (f != null) {
                String u = fileThumb(f);
                if (u != null) return u;
            }
        }

        // 2) fallback: score image filenames - poster-like + title overlap
        JSONArray images = page.optJSONArray("images");
        if (images == null) return null;
        List<String> ttoks = titleTokens(clean);
        String pick = null;
        int best = -999;
        for (int i = 0; i < images.length(); i++) {
            String n;
            try { n = images.getJSONObject(i).optString("title", ""); }
            catch (Exception e) { continue; }
            if (n.startsWith("File:")) n = n.substring(5);
            String base = n.replaceAll("(?i)\\.(jpe?g|png|webp)$", "");
            String[] ftoks = normFileName(base).split("\\s+");
            int score = 0;
            if (n.matches("(?i).*poster.*")) score += 4;
            if (n.matches("(?i).*(theatrical|teaser|promotional|promote|banner|key art|one sheet).*")) score += 2;
            if (n.matches("(?i).*(screenshot|screen shot|cover|dvd|blu-?ray|logotype|poster for|advert|wallpaper|stills|behind|interview|event|launch|ceremony|award|red.?carpet|airport).*")) score -= 10;
            if (n.matches("(?i).*\\.(jpe?g|png|webp)$")) score += 1;
            int hit = 0;
            for (String w : ttoks) for (String ft : ftoks) if (ft.equals(w)) { hit++; break; }
            score += Math.min(8, hit * 2);
            int extra = ftoks.length - ttoks.size();
            if (extra <= 1 && hit > 0) score += 3;
            else if (extra > 4) score -= 2;
            if (score > best) { best = score; pick = n; }
        }
        if (pick == null || best <= 0) return null;
        return fileThumb(pick);
    }

    private static String posterTvmaze(String title) {
        try {
            String clean = cleanTitle(title);
            if (clean.isEmpty()) return null;
            String body = metaGet("https://api.tvmaze.com/search/shows?q=" + URLEncoder.encode(clean, "UTF-8"));
            if (body == null) return null;
            JSONArray arr = new JSONArray(body);
            if (arr.length() == 0) return null;
            JSONObject show = arr.getJSONObject(0).optJSONObject("show");
            if (show == null) return null;
            JSONObject img = show.optJSONObject("image");
            if (img == null) return null;
            String u = img.optString("original", null);
            if (u == null) u = img.optString("medium", null);
            return u;
        } catch (Exception e) { return null; }
    }

    static String posterImage(String title, String path) {
        if (title == null || title.isEmpty()) return null;
        String key = (title + "|" + path).toLowerCase(Locale.ROOT);
        synchronized (POSTER_LOCK) {
            if (POSTERS.containsKey(key)) return POSTERS.get(key);
        }
        String img = null;
        try {
            boolean series = (path != null && path.matches("(?i).*(series|season|episode).*"))
                    || title.matches("(?i).*(\\bseries\\b|\\bseason\\s*\\d|\\bs\\d{1,2}e\\d).*");
            if (series) img = posterTvmaze(title);
            if (img == null) img = posterWiki(title);
            if (img == null && !series) img = posterTvmaze(title);
        } catch (Exception ignored) { }
        synchronized (POSTER_LOCK) { POSTERS.put(key, img); }
        return img;
    }

    static JSONObject movieJson(String path) {
        return movieJson(path, "moviezda");
    }

    static JSONObject movieJson(String path, String site) {
        return movieJson(path, site, null);
    }

    static JSONObject movieJson(String path, String site, String title) {
        JSONObject out = new JSONObject();
        boolean isai = "isaidub".equals(site);
        String base = isai ? ISAI : BASE;
        try {
            List<Item> items = isai ? treeIsai(path, 0, "", "") : tree(path, 0, "", "");
            JSONArray arr = new JSONArray();
            for (Item it : items) {
                Variant v;
                try { v = details(it.dpath, site); }
                catch (Exception e) { v = new Variant(); }

                // isaiDub: no dubpage link -> fall back to the download page
                // itself; the chain resolver knows how to walk it.
                String server = v.server;
                if (isai && (server == null || server.isEmpty())) server = base + it.dpath;

                JSONObject j = new JSONObject();
                j.put("section", it.section);
                j.put("quality", it.quality);
                j.put("file", v.file.isEmpty() ? it.file : v.file);
                j.put("size", v.size.isEmpty() ? it.size : v.size);
                j.put("resolution", v.resolution);
                j.put("duration", v.duration);
                j.put("format", v.format.isEmpty() ? it.format : v.format);
                j.put("added", v.added);
                j.put("page", base + it.dpath);
                j.put("server", server);
                j.put("watch", v.watch);
                arr.put(j);
            }
            String img = posterImage(title, path);
            if (img != null) out.put("img", img);
            out.put("ok", true);
            out.put("url", path);
            out.put("site", site);
            out.put("variants", arr);
        } catch (Exception e) {
            try { out.put("ok", false); out.put("error", String.valueOf(e.getMessage())); }
            catch (Exception ignored) { }
        }
        return out;
    }

    // ---------------------------------------------------------------- resolve

    // URL path ends in a media extension -> it IS the file, probe don't download
    private static boolean mediaPath(String url) {
        try {
            String p = new URL(url).getPath();
            return p != null && p.toLowerCase(Locale.ROOT)
                    .matches(".*\\.(mp4|mkv|avi|webm|m4v|flv|mov|ts|mpg|mpeg|3gp|wmv)$");
        } catch (Exception e) {
            return false;
        }
    }

    static JSONObject linkJson(String start) {
        return linkJson(start, "moviezda");
    }

    static JSONObject linkJson(String start, String site) {
        JSONObject out = new JSONObject();
        JSONArray chain = new JSONArray();
        String base = "isaidub".equals(site) ? ISAI : BASE;
        String url = start.startsWith("http") ? start : base + start;
        try {
            for (int i = 0; i < 12; i++) {
                if (!allowed(url)) {
                    chain.put(hop(url, 0, "BLOCKED (not in allow-list)"));
                    out.put("ok", false);
                    out.put("error", "Blocked redirect to " + url);
                    out.put("chain", chain);
                    return out;
                }

                // Final CDN object: never download it, just read the first 2 bytes.
                //   moviezda -> *.r2.cloudflarestorage.com/...
                //   isaiDub  -> *.uptodub.ch/files/... or any *.dubshare.one/*.mp4
                boolean isCdn = url.contains(".r2.cloudflarestorage.com/")
                        || url.contains(".uptodub.ch/files/")
                        || mediaPath(url);
                if (isCdn) {
                    Res r = get(url, "0-1", 1048576);
                    chain.put(hop(url, r.status, "direct CDN file"));
                    out.put("ok", true);
                    out.put("final", url);
                    out.put("status", r.status);
                    out.put("type", r.type == null ? "video/mp4" : r.type);
                    out.put("bytes", r.total);
                    out.put("chain", chain);
                    return out;
                }

                Res r = get(url, null);
                chain.put(hop(url, r.status, r.type == null ? "" : r.type));

                if ((r.status == 301 || r.status == 302 || r.status == 303 || r.status == 307 || r.status == 308)
                        && r.location != null) {
                    url = new URL(new URL(url), r.location).toString();
                    continue;
                }

                if (r.type != null && r.type.contains("text/html")) {
                    String next = null;
                    if (url.contains("isaidub.green/download/")) next = firstHref(r.text, "dubpage\\.xyz/download/view/\\d+");
                    else if (url.contains("dubpage.xyz"))          next = firstHref(r.text, "dubmv\\.xyz/download/file/\\d+");
                    else if (url.contains("dubmv.xyz"))            next = firstHref(r.text, "(dub\\.uptodub\\.ch|download\\.isaidub\\.dad)/download\\.php");
                    else if (url.contains("moviezda.me/download/")) next = firstHref(r.text, "download\\.moviespage\\.xyz/download/file/\\d+");
                    else if (url.contains("moviespage.xyz"))       next = firstHref(r.text, "movies\\.downloadpage\\.xyz/download/page/\\d+");
                    else if (url.contains("downloadpage.xyz"))     next = firstHref(r.text, "fastbytes\\.xyz/download\\.php");
                    if (next != null) { url = next; continue; }

                    out.put("ok", false);
                    out.put("error", "Could not find the next download link.");
                    out.put("chain", chain);
                    return out;
                }

                if (r.status == 200 || r.status == 206) {
                    out.put("ok", true);
                    out.put("final", url);
                    out.put("status", r.status);
                    out.put("type", r.type);
                    out.put("bytes", r.total);
                    out.put("chain", chain);
                    return out;
                }

                out.put("ok", false);
                out.put("error", "Unexpected HTTP " + r.status);
                out.put("chain", chain);
                return out;
            }
            out.put("ok", false);
            out.put("error", "Too many hops.");
            out.put("chain", chain);
        } catch (Exception e) {
            try {
                out.put("ok", false);
                out.put("error", String.valueOf(e.getMessage()));
                out.put("chain", chain);
            } catch (Exception ignored) { }
        }
        return out;
    }

    private static JSONObject hop(String url, int status, String note) throws Exception {
        return new JSONObject().put("url", url).put("status", status).put("note", note);
    }
}
