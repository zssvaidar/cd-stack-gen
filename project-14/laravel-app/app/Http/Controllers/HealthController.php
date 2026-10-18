<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\DB;
use Throwable;

class HealthController extends Controller
{
    /**
     * Liveness: the PHP process is up and can serve a request.
     */
    public function live(): JsonResponse
    {
        return response()->json(['status' => 'UP']);
    }

    /**
     * Readiness: dependencies (database) are reachable.
     */
    public function ready(): JsonResponse
    {
        $checks = ['database' => 'UP'];

        try {
            DB::connection()->getPdo();
        } catch (Throwable $e) {
            $checks['database'] = 'DOWN';
        }

        $up = ! in_array('DOWN', $checks, true);

        return response()->json([
            'status' => $up ? 'UP' : 'DOWN',
            'checks' => $checks,
        ], $up ? 200 : 503);
    }
}
