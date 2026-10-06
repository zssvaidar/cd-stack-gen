<?php

declare(strict_types=1);

namespace App\Tests;

use App\HealthCheck;
use PHPUnit\Framework\TestCase;

final class HealthCheckTest extends TestCase
{
    public function testOkWhenAppNameSet(): void
    {
        $check = new HealthCheck(['APP_NAME' => 'mock-app']);
        $this->assertTrue($check->appNameConfigured());
        $this->assertSame(['app' => 'mock-app', 'ok' => true], $check->status());
    }

    public function testNotOkWhenAppNameMissing(): void
    {
        $check = new HealthCheck([]);
        $this->assertFalse($check->appNameConfigured());
        $this->assertSame(['app' => null, 'ok' => false], $check->status());
    }
}
