<?php

declare(strict_types=1);

namespace App;

/**
 * Stands in for a real app's health/readiness endpoint logic - checks the
 * things a Laravel app's /up route would check (config present, DB
 * reachable), without pulling in a framework for what is a build/deploy
 * pipeline demo.
 */
final class HealthCheck
{
    /**
     * @param array<string, string|false> $env Injected explicitly (not read from
     *   $_ENV directly) so this class stays testable without mutating global state.
     */
    public function __construct(private readonly array $env)
    {
    }

    public function appNameConfigured(): bool
    {
        $name = $this->env['APP_NAME'] ?? false;
        return is_string($name) && $name !== '';
    }

    public function status(): array
    {
        return [
            'app' => $this->appNameConfigured() ? $this->env['APP_NAME'] : null,
            'ok' => $this->appNameConfigured(),
        ];
    }
}
