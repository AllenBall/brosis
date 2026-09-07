"""Reproduce the feasibility report's FTS assumptions with synthetic data only."""
import sqlite3


def main():
    con = sqlite3.connect(":memory:")
    print("SQLite", sqlite3.sqlite_version)
    variants = [
        ("u", "tokenize='unicode61'"),
        ("t", "tokenize='trigram', detail=column"),
        ("f", "tokenize='trigram', detail=full"),
    ]
    for name, options in variants:
        con.execute(f"CREATE VIRTUAL TABLE {name} USING fts5(text, {options})")
        con.execute(
            f"INSERT INTO {name}(text) VALUES (?)",
            ("项目计划与知识图谱 research",),
        )
        for query in ["项目", "知识图谱", "research"]:
            try:
                rows = con.execute(
                    f"SELECT rowid FROM {name} WHERE {name} MATCH ?", (query,)
                ).fetchall()
                print(name, repr(query), rows)
            except sqlite3.OperationalError as error:
                print(name, repr(query), "ERROR:", str(error))
    con.close()


if __name__ == "__main__":
    main()
