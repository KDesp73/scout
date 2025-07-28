BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTSAL TABLE PageIndex USING fts5(
    title,
    description,
    keywords,
    content,
    url UNINDEXED
);
CREATE TABLE IF NOT EXISTS "PageIndex_config" (
	"k"	,
	"v"	,
	PRIMARY KEY("k")
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS "PageIndex_content" (
	"id"	INTEGER,
	"c0"	,
	"c1"	,
	"c2"	,
	"c3"	,
	"c4"	,
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "PageIndex_data" (
	"id"	INTEGER,
	"block"	BLOB,
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "PageIndex_docsize" (
	"id"	INTEGER,
	"sz"	BLOB,
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "PageIndex_idx" (
	"segid"	,
	"term"	,
	"pgno"	,
	PRIMARY KEY("segid","term")
) WITHOUT ROWID;
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
