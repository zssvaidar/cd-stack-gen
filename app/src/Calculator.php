<?php

declare(strict_types=1);

namespace App;

/**
 * Trivial domain class purely so build.sh/test.sh have something with real
 * branches to run PHPUnit against.
 */
final class Calculator
{
    public function add(int $a, int $b): int
    {
        return $a + $b;
    }

    public function divide(int $a, int $b): float
    {
        if ($b === 0) {
            throw new \DivisionByZeroError('Cannot divide by zero');
        }
        return $a / $b;
    }
}
