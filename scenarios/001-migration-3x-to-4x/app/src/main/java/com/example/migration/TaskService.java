package com.example.migration;

import java.util.List;

import org.springframework.stereotype.Service;

/**
 * 題材のサービス層。
 *
 * テストで差し替える対象を作るために置いている。差し替えの手段が
 * 3 系と 4 系で変わる（{@code @MockBean} → {@code @MockitoBean}）ことが、
 * 本シナリオが数える対象のひとつである。
 */
@Service
public class TaskService {

    /** 固定の一覧を返す。永続化は測定に関係しないため持たない。 */
    public List<Task> findAll() {
        return List.of(
                new Task(1L, "書く", false),
                new Task(2L, "測る", true));
    }
}
