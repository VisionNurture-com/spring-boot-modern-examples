package com.example.migration;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 素の JUnit テスト。
 *
 * 対照として置く。JUnit Jupiter が 5 系から 6 系へ上がっても
 * テストコードを変えずに通るかどうかを、このクラスで見る。
 */
class TaskServiceTest {

    @Test
    void 一覧は2件返る() {
        assertThat(new TaskService().findAll()).hasSize(2);
    }
}
