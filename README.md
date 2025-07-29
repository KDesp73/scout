# scout

> A fast, local-first search engine built in Zig

`scout` lets you crawl and index websites locally, then search them offline using full-text search powered by SQLite FTS5.

---

## 🚀 Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/KDesp73/scout && cd scout
```

### 2. Build with Zig

```bash
zig build
```

### 3. Initialize the Database

```bash
scout init
```

### 4. Start Crawling

```bash
scout crawl --seed "wikipedia.org" --infinite
```

### 5. Search the Index

```bash
scout query --input "your search terms here"
```

---

## Features

* Website crawler with depth control
* Indexing of page titles, descriptions, and full content
* Local full-text search via SQLite FTS5
* CLI-first interface with easy commands
* Extensible and written in Zig

## Requirements

* [Zig 0.14.1](https://ziglang.org/download/)
* SQLite with FTS5 support
* A Unix-like system (Linux/macOS)

## Example Commands

```bash
# Crawl a single host
scout crawl --seed "example.com" --depth 2

# View visited pages
scout list --pages

# Check the crawl queue
scout list --queue

# Perform a search
scout query --input "example term"

# Run just the parser
scout parse --host "example.com"
```

## License

[MIT](./LICENSE)
