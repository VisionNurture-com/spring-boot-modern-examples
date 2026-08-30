package com.example.migration;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.BDDMockito.given;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * スライステスト。
 *
 * 🔴 本クラスは 4 系で壊れる箇所を意図的に 2 つ含む。
 * <ul>
 *   <li>{@code @MockBean} —— 4 系で削除され {@code @MockitoBean} に置き換わる</li>
 *   <li>{@code org.springframework.boot.test.autoconfigure.web.servlet} —— パッケージが移る</li>
 * </ul>
 */
@WebMvcTest(TaskController.class)
class TaskControllerTest {

    @Autowired
    private MockMvc mvc;

    @MockBean
    private TaskService service;

    @Test
    void 一覧を返す() throws Exception {
        given(service.findAll()).willReturn(List.of(new Task(1L, "書く", false)));

        mvc.perform(get("/tasks"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].name").value("書く"));
    }
}
