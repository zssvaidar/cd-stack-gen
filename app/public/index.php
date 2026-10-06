<?php

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use App\HealthCheck;

// Real Laravel apps front-controller through this same public/index.php path
// (bootstrap the framework kernel instead of this by-hand routing) - nginx/
// apache both just point at public/ and let this file handle everything,
// which is why the server configs in ../docker/ don't need to change to
// serve a real Laravel app instead of this mock one.
$check = new HealthCheck($_ENV);
$status = $check->status();

header('Content-Type: application/json');
http_response_code($status['ok'] ? 200 : 503);
echo json_encode($status, JSON_PRETTY_PRINT);
