package com.example.migration;

/**
 * 題材のドメイン。処理の中身は測定に関係しないため最小限にとどめる。
 *
 * @param id   識別子
 * @param name 表示名
 * @param done 完了しているか
 */
public record Task(long id, String name, boolean done) {
}
