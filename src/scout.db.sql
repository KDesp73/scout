BEGIN TRANSACTION;
CREATE VIRTUAL TABLE IF NOT EXISTS PageIndex USING fts5(
    title,
    description,
    keywords,
    content,
    url UNINDEXED
);
CREATE TABLE IF NOT EXISTS "Pages" (
	"url"	TEXT,
	"title"	TEXT,
	"description"	TEXT,
	"keywords"	TEXT,
	"content"	TEXT,
	"host"	TEXT,
	"timestamp"	INTEGER DEFAULT (strftime('%s', 'now')),
	PRIMARY KEY("url")
);
CREATE TABLE IF NOT EXISTS "Queue" (
	"url"	TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "idx_pages_host" ON "Pages" (
	"host"
);
CREATE INDEX IF NOT EXISTS "idx_pages_timestamp" ON "Pages" (
	"timestamp"
);
COMMIT;
