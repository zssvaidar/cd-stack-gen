<?php

use App\Http\Controllers\HealthController;
use Illuminate\Support\Facades\Route;

// Registered outside the "web" group: no session, cookies or CSRF, so load
// balancer probes stay cheap and don't depend on the session store.
Route::get('/health', [HealthController::class, 'live']);
Route::get('/health/ready', [HealthController::class, 'ready']);
