package com.example.springapp;

import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

	@GetMapping("/")
	public Map<String, String> hello() {
		return Map.of("app", "spring-app", "message", "Hello from Spring Boot");
	}

}
