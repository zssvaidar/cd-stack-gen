<?php

namespace Tests\Feature;

use Tests\TestCase;

class HealthTest extends TestCase
{
    public function test_liveness_returns_up(): void
    {
        $this->getJson('/health')->assertOk()->assertJson(['status' => 'UP']);
    }

    public function test_readiness_checks_database(): void
    {
        $this->getJson('/health/ready')
            ->assertOk()
            ->assertJson(['status' => 'UP', 'checks' => ['database' => 'UP']]);
    }

    public function test_builtin_up_route(): void
    {
        $this->get('/up')->assertOk();
    }
}
