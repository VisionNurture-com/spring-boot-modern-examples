package com.example.migration;

import java.util.List;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * 題材のコントローラ。
 *
 * 🔴 Jackson を明示的に import している。framework 任せにすると
 * groupId の変更（{@code com.fasterxml.jackson} → {@code tools.jackson}）が
 * ソースに当たらず、推移依存の major バンプ型を数えられないためである。
 */
@RestController
public class TaskController {

    private final TaskService service;
    private final ObjectMapper mapper = new ObjectMapper();

    public TaskController(TaskService service) {
        this.service = service;
    }

    @GetMapping("/tasks")
    public List<Task> tasks() {
        return service.findAll();
    }

    /** 明示的に JSON 文字列へ直して返す。Jackson の API をソースで使うための経路。 */
    @GetMapping("/tasks.json")
    public String tasksAsJson() throws JsonProcessingException {
        return mapper.writeValueAsString(service.findAll());
    }
}
