package me.moviezda.crawler;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.util.Log;

import org.json.JSONObject;

/**
 * SQLite cache for scraped data.
 *
 * movie  - one row per movie path, holds the whole /api/movie JSON (variants,
 *          sizes, resolutions, server links).  TTL 6 h, stale rows are kept
 *          so an offline launch can still show sizes.
 * link   - one row per moviespage server URL, holds the resolved final CDN
 *          URL.  TTL 12 h; the signed CDN URL itself lives 48 h.
 *
 * Rows are capped and the oldest are pruned so the DB cannot grow forever.
 */
final class Db extends SQLiteOpenHelper {

    private static final String TAG = "MoviezdaDb";
    private static final String NAME = "cache.db";
    private static final int VERSION = 1;

    static final long MOVIE_TTL = 6L * 60 * 60 * 1000;   // 6 hours
    static final long LINK_TTL  = 12L * 60 * 60 * 1000;  // 12 hours
    private static final int MAX_MOVIES = 200;
    private static final int MAX_LINKS  = 500;

    Db(Context c) {
        super(c, NAME, null, VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE movie (" +
                "url TEXT PRIMARY KEY," +
                "json TEXT NOT NULL," +
                "ts INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE link (" +
                "server TEXT PRIMARY KEY," +
                "json TEXT NOT NULL," +
                "ts INTEGER NOT NULL)");
        db.execSQL("CREATE INDEX movie_ts ON movie (ts)");
        db.execSQL("CREATE INDEX link_ts ON link (ts)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldV, int newV) {
        db.execSQL("DROP TABLE IF EXISTS movie");
        db.execSQL("DROP TABLE IF EXISTS link");
        onCreate(db);
    }

    // ------------------------------------------------------------------ movie

    JSONObject getMovie(String url, long maxAge) {
        return read("movie", "url", url, maxAge);
    }

    JSONObject getMovieAnyAge(String url) {
        return read("movie", "url", url, Long.MAX_VALUE);
    }

    void putMovie(String url, JSONObject json) {
        write("movie", "url", url, json, MAX_MOVIES);
    }

    // ------------------------------------------------------------------- link

    JSONObject getLink(String server, long maxAge) {
        return read("link", "server", server, maxAge);
    }

    void putLink(String server, JSONObject json) {
        write("link", "server", server, json, MAX_LINKS);
    }

    // ------------------------------------------------------------------ stats

    long movieCount() { return count("movie"); }
    long linkCount()  { return count("link");  }

    private long count(String table) {
        Cursor c = null;
        try {
            c = getReadableDatabase().rawQuery("SELECT COUNT(*) FROM " + table, null);
            return c.moveToFirst() ? c.getLong(0) : 0;
        } catch (Exception e) {
            return 0;
        } finally {
            if (c != null) c.close();
        }
    }

    // ------------------------------------------------------------------ core

    private JSONObject read(String table, String key, String value, long maxAge) {
        Cursor c = null;
        try {
            c = getReadableDatabase().query(table, new String[]{"json", "ts"},
                    key + "=?", new String[]{value}, null, null, null, "1");
            if (c.moveToFirst()) {
                long age = System.currentTimeMillis() - c.getLong(1);
                if (age <= maxAge) {
                    JSONObject j = new JSONObject(c.getString(0));
                    Log.d(TAG, table + " hit (" + (age / 1000) + "s old) " + value);
                    return j;
                }
                Log.d(TAG, table + " expired (" + (age / 1000) + "s old) " + value);
            }
        } catch (Exception e) {
            Log.w(TAG, table + " read failed: " + e.getMessage());
        } finally {
            if (c != null) c.close();
        }
        return null;
    }

    private void write(String table, String key, String value, JSONObject json, int limit) {
        try {
            ContentValues cv = new ContentValues();
            cv.put(key, value);
            cv.put("json", json.toString());
            cv.put("ts", System.currentTimeMillis());
            getWritableDatabase().insertWithOnConflict(table, null, cv,
                    SQLiteDatabase.CONFLICT_REPLACE);

            getWritableDatabase().execSQL(
                    "DELETE FROM " + table + " WHERE " + key + " NOT IN " +
                    "(SELECT " + key + " FROM " + table + " ORDER BY ts DESC LIMIT " + limit + ")");
            Log.d(TAG, table + " stored " + value);
        } catch (Exception e) {
            Log.w(TAG, table + " write failed: " + e.getMessage());
        }
    }
}
