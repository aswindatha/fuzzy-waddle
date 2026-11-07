package me.moviezda.crawler;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * Hosts the single-file UI inside a WebView and answers /api/* itself.
 *
 * The page is loaded from https://app.local/ - a host that only exists inside
 * this app. shouldInterceptRequest() returns the bundled HTML and the JSON the
 * scraper builds, so the page is "same origin" and needs no CORS workaround,
 * no local server and no extra permissions.
 *
 * Scrape results are cached in SQLite (Db.java): movie JSON for 6 h and
 * resolved signed CDN links for 12 h.  A cold launch of a cached movie is
 * instant and still shows sizes and variants offline.
 */
public class MainActivity extends Activity {

    private static final String TAG = "MoviezdaApp";
    private static final String HOST = "app.local";
    private static final String ASSET = "moviezda-crawler.html";

    private WebView web;
    private Db db;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        db = new Db(this);

        web = new WebView(this);
        web.setLayoutParams(new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        web.setBackgroundColor(0xFF0B0D10);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
                Uri u = req.getUrl();
                if (u == null || !HOST.equals(u.getHost())) return notFound();
                return route(u);
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                // Never let the app wander off to an ad page. External sites
                // are opened in the real browser through Bridge.openSite().
                Uri u = req.getUrl();
                return u == null || !HOST.equals(u.getHost());
            }
        });

        web.addJavascriptInterface(new Bridge(), "Android");
        setContentView(web);
        web.loadUrl("https://" + HOST + "/");
    }

    // ------------------------------------------------------------------ routes

    private WebResourceResponse route(Uri u) {
        String path = u.getPath() == null ? "/" : u.getPath();
        try {
            if ("/".equals(path) || "/index.html".equals(path)) {
                return new WebResourceResponse("text/html", "utf-8", openAsset());
            }

            if ("/api/health".equals(path)) {
                JSONObject h = new JSONObject()
                        .put("ok", true)
                        .put("index", -1)
                        .put("version", 4)
                        .put("platform", "android")
                        .put("movies", db.movieCount())
                        .put("links", db.linkCount());
                return json(h.toString());
            }

            if ("/api/movie".equals(path)) {
                String target = u.getQueryParameter("u");
                if (target == null) return json("{\"ok\":false,\"error\":\"missing u\"}");
                String site = "isaidub".equals(u.getQueryParameter("site")) ? "isaidub" : "moviezda";
                String title = u.getQueryParameter("t");
                String key = site + "|" + target;

                JSONObject cached = db.getMovie(key, Db.MOVIE_TTL);
                if (cached != null) {
                    ensureImg(cached, title, target, key);
                    cached.put("cached", true);
                    return json(cached.toString());
                }

                JSONObject fresh = Scraper.movieJson(target, site, title);
                if (fresh.optBoolean("ok")) {
                    db.putMovie(key, fresh);
                    return json(fresh.toString());
                }

                // network failed - fall back to the old row so sizes still show
                JSONObject stale = db.getMovieAnyAge(key);
                if (stale != null) {
                    ensureImg(stale, title, target, key);
                    stale.put("stale", true);
                    Log.d(TAG, "movie offline fallback " + key);
                    return json(stale.toString());
                }
                return json(fresh.toString());
            }

            if ("/api/link".equals(path)) {
                String target = u.getQueryParameter("u");
                if (target == null) return json("{\"ok\":false,\"error\":\"missing u\"}");
                String site = "isaidub".equals(u.getQueryParameter("site")) ? "isaidub" : "moviezda";
                String key = site + "|" + target;

                JSONObject cached = db.getLink(key, Db.LINK_TTL);
                if (cached != null) {
                    cached.put("cached", true);
                    return json(cached.toString());
                }

                JSONObject fresh = Scraper.linkJson(target, site);
                if (fresh.optBoolean("ok")) db.putLink(key, fresh);
                return json(fresh.toString());
            }
        } catch (Exception e) {
            String msg = String.valueOf(e.getMessage()).replace("\\", "\\\\").replace("\"", "\\\"");
            return json("{\"ok\":false,\"error\":\"" + msg + "\"}");
        }
        return notFound();
    }

    // backfill poster on cached rows fetched before the img field existed
    private void ensureImg(JSONObject j, String title, String target, String key) {
        try {
            if (title == null || j.has("img")) return;
            String img = Scraper.posterImage(title, target);
            if (img != null) {
                j.put("img", img);
                db.putMovie(key, j);
            }
        } catch (Exception ignored) { }
    }

    private InputStream openAsset() throws Exception {
        return getAssets().open(ASSET);
    }

    private WebResourceResponse json(String body) {
        return new WebResourceResponse("application/json", "utf-8",
                new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8)));
    }

    private WebResourceResponse notFound() {
        return new WebResourceResponse("text/plain", "utf-8",
                new ByteArrayInputStream("not found".getBytes(StandardCharsets.UTF_8)));
    }

    // ------------------------------------------------------------------ bridge

    public class Bridge {

        @JavascriptInterface
        public void download(final String url, final String name) {
            if (url == null || !Scraper.allowed(url)) return;

            String safe = name == null ? "video.mp4" : name.replaceAll("[\\\\/:*?\"<>|]", "_");
            if (!safe.toLowerCase(Locale.ROOT).endsWith(".mp4")) safe = safe + ".mp4";

            try {
                DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
                req.setTitle(safe);
                req.setMimeType("video/mp4");
                req.setNotificationVisibility(
                        DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                req.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safe);

                DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
                dm.enqueue(req);
                Log.d(TAG, "download queued " + safe + " " + url.length() + " url chars");

                runOnUiThread(new Runnable() {
                    public void run() {
                        Toast.makeText(MainActivity.this,
                                "Download queued - check your notifications",
                                Toast.LENGTH_SHORT).show();
                    }
                });
            } catch (final Exception e) {
                Log.w(TAG, "download failed: " + e.getMessage());
                runOnUiThread(new Runnable() {
                    public void run() {
                        Toast.makeText(MainActivity.this,
                                "Download failed: " + e.getMessage(), Toast.LENGTH_LONG).show();
                    }
                });
            }
        }

        @JavascriptInterface
        public void copy(final String text) {
            if (text == null) return;
            try {
                ClipboardManager cm =
                        (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                cm.setPrimaryClip(ClipData.newPlainText("Moviezda link", text));
                Log.d(TAG, "clipboard set " + text.length() + " chars");
            } catch (Exception e) {
                Log.w(TAG, "clipboard failed: " + e.getMessage());
            }
        }

        @JavascriptInterface
        public void openSite(final String url) {
            try {
                Uri u = Uri.parse(url);
                String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
                boolean ok = "https".equals(u.getScheme())
                        && ("moviezda.me".equals(host) || "www.moviezda.me".equals(host)
                            || "isaidub.green".equals(host) || "www.isaidub.green".equals(host));
                if (!ok) {
                    Log.w(TAG, "openSite refused " + url);
                    return;
                }
                Intent i = new Intent(Intent.ACTION_VIEW, u);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(i);
                Log.d(TAG, "openSite " + url);
            } catch (Exception e) {
                Log.w(TAG, "openSite failed: " + e.getMessage());
            }
        }

        @JavascriptInterface
        public boolean supported() {
            return true;
        }
    }

    // ------------------------------------------------------------------ lifecycle

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.setVisibility(View.GONE);
            web.destroy();
            web = null;
        }
        if (db != null) {
            db.close();
            db = null;
        }
        super.onDestroy();
    }
}
