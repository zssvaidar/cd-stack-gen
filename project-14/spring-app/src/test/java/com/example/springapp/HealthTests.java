package com.example.springapp;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest
@AutoConfigureMockMvc
class HealthTests {

	@Autowired
	private MockMvc mvc;

	@Test
	void healthIsUp() throws Exception {
		mvc.perform(get("/actuator/health")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("UP"));
	}

	@Test
	void livenessAndReadinessAreUp() throws Exception {
		mvc.perform(get("/actuator/health/liveness")).andExpect(status().isOk());
		mvc.perform(get("/actuator/health/readiness")).andExpect(status().isOk());
	}

	@Test
	void rootResponds() throws Exception {
		mvc.perform(get("/")).andExpect(status().isOk()).andExpect(jsonPath("$.app").value("spring-app"));
	}

}
