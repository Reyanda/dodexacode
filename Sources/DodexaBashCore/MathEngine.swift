import Foundation

// MARK: - University-level Mathematics Engine
// Arithmetic, algebra, trigonometry, calculus, linear algebra, statistics, number theory

public enum MathEngine {

    // MARK: - Main Entry Point

    public static func evaluate(_ input: String) -> String? {
        let expr = input.trimmingCharacters(in: .whitespaces)
        guard !expr.isEmpty else { return nil }
        let lowered = expr.lowercased()

        // Calculus
        if lowered.hasPrefix("deriv") || lowered.hasPrefix("d/dx") { return derivative(expr) }
        if lowered.hasPrefix("integrate") || lowered.hasPrefix("integral") || lowered.hasPrefix("int ") { return integral(expr) }
        if lowered.hasPrefix("limit") || lowered.hasPrefix("lim ") { return limit(expr) }
        if lowered.hasPrefix("taylor") { return taylor(expr) }
        if lowered.hasPrefix("solve") { return solve(expr) }

        // Statistics
        if lowered.hasPrefix("mean ") || lowered.hasPrefix("avg ") { return stats(expr, op: "mean") }
        if lowered.hasPrefix("median ") { return stats(expr, op: "median") }
        if lowered.hasPrefix("stdev ") || lowered.hasPrefix("std ") { return stats(expr, op: "stdev") }
        if lowered.hasPrefix("variance ") || lowered.hasPrefix("var ") { return stats(expr, op: "variance") }
        if lowered.hasPrefix("sum ") { return stats(expr, op: "sum") }
        if lowered.hasPrefix("product ") { return stats(expr, op: "product") }

        // Number theory
        if lowered.hasPrefix("factor ") { return factor(expr) }
        if lowered.hasPrefix("gcd ") { return gcdCalc(expr) }
        if lowered.hasPrefix("lcm ") { return lcmCalc(expr) }
        if lowered.hasPrefix("isprime ") { return isPrime(expr) }
        if lowered.hasPrefix("fibonacci ") || lowered.hasPrefix("fib ") { return fibonacci(expr) }
        if lowered.hasPrefix("nck ") || lowered.hasPrefix("choose ") || lowered.hasPrefix("comb ") { return combination(expr) }
        if lowered.hasPrefix("npr ") || lowered.hasPrefix("perm ") { return permutation(expr) }
        if lowered.hasPrefix("factorial ") || lowered.hasPrefix("fact ") { return factorial(expr) }

        // Real analysis
        if lowered.hasPrefix("series ") { return series(expr) }
        if lowered.hasPrefix("converges ") || lowered.hasPrefix("convergence ") { return convergence(expr) }
        if lowered.hasPrefix("continuous ") || lowered.hasPrefix("continuity ") { return continuity(expr) }
        if lowered.hasPrefix("riemann ") { return riemann(expr) }
        if lowered.hasPrefix("sequence ") || lowered.hasPrefix("seq ") { return sequence(expr) }
        if lowered.hasPrefix("supremum ") || lowered.hasPrefix("sup ") { return supremum(expr) }
        if lowered.hasPrefix("infimum ") || lowered.hasPrefix("inf ") && !lowered.hasPrefix("inf") { return infimum(expr) }

        // Graph theory
        if lowered.hasPrefix("degree ") { return graphDegree(expr) }
        if lowered.hasPrefix("adjacent ") || lowered.hasPrefix("adj ") { return graphAdjacent(expr) }
        if lowered.hasPrefix("path ") { return graphPath(expr) }
        if lowered.hasPrefix("euler ") { return graphEuler(expr) }
        if lowered.hasPrefix("chromatic ") { return graphChromatic(expr) }

        // Unit conversion
        if lowered.contains(" to ") { return unitConversion(lowered) }

        // Matrix operations
        if lowered.hasPrefix("det ") { return determinant(expr) }
        if lowered.hasPrefix("trace ") { return trace(expr) }
        if lowered.hasPrefix("transpose ") { return transpose(expr) }
        if lowered.hasPrefix("eigenvalues ") || lowered.hasPrefix("eigen ") { return eigenvalues2x2(expr) }

        // Standard arithmetic/scientific expression
        guard let result = evaluateExpression(expr) else { return nil }
        return formatResult(result)
    }

    public static func help() -> String {
        """
        calc <expression>

        Arithmetic:    4+9, (2+3)*4, 100/3, 2^10, 17%5
        Scientific:    sin(pi/4), cos(60deg), log(100), sqrt(144), cbrt(27)
        Constants:     pi, e, tau, phi (golden ratio), inf
        Trig:          sin, cos, tan, asin, acos, atan, sinh, cosh, tanh
        Logarithms:    log (base 10), ln (natural), log2, exp
        Other:         abs, ceil, floor, round, sqrt, cbrt, sign, max, min

        Calculus:
          deriv x^2 at 3                    numerical derivative
          deriv sin(x) at pi/4              derivative at a point
          integrate x^2 0 1                 definite integral (Simpson's rule)
          integrate sin(x) 0 pi             definite integral
          limit sin(x)/x at 0              limit
          limit 1/x at 0+                  right-sided limit
          taylor sin(x) at 0 order 5       Taylor series coefficients
          solve x^2-4 near 2               Newton's method root finding

        Statistics:
          mean 1 2 3 4 5                   arithmetic mean
          median 1 2 3 4 5                 median
          stdev 1 2 3 4 5                  standard deviation
          variance 1 2 3 4 5              variance
          sum 1 2 3 4 5                    summation
          product 1 2 3 4 5               product

        Number Theory:
          factor 360                       prime factorization
          gcd 12 18                        greatest common divisor
          lcm 4 6                          least common multiple
          isprime 97                       primality test
          factorial 10                     10!
          choose 10 3                      C(10,3) combination
          perm 10 3                        P(10,3) permutation
          fibonacci 20                     20th Fibonacci number

        Linear Algebra:
          det [[1,2],[3,4]]                determinant

        Conversion:
          72F to C                         temperature
          5km to miles                     distance
          10lb to kg                       mass
          45deg to rad                     angles

        """
    }

    // MARK: - Expression Evaluator

    public static func evaluateExpression(_ expr: String) -> Double? {
        var cleaned = expr
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "**", with: "^")

        // Degree to radian for trig: sin(45deg)
        cleaned = cleaned.replacingOccurrences(of: "deg)", with: "*\(Double.pi)/180)")

        // Constants
        cleaned = replaceConstants(cleaned)

        // Evaluate function calls recursively
        cleaned = evaluateFunctions(cleaned)

        let tokens = tokenize(cleaned)
        return parseAddSub(tokens: tokens, index: 0)?.value
    }

    private static func replaceConstants(_ expr: String) -> String {
        var result = expr
        // Order matters: longer names first
        let constants: [(String, String)] = [
            ("tau", String(Double.pi * 2)),
            ("phi", String((1 + sqrt(5)) / 2)),
            ("pi", String(Double.pi)),
        ]
        for (name, value) in constants {
            // Only replace if not part of a longer word
            result = result.replacingOccurrences(
                of: "(?<![a-z])\(name)(?![a-z])",
                with: value,
                options: .regularExpression
            )
        }
        // e — careful not to replace inside exp, ceil, etc.
        result = result.replacingOccurrences(
            of: "(?<![a-z])e(?![a-z])",
            with: String(M_E),
            options: .regularExpression
        )
        return result
    }

    private static func evaluateFunctions(_ expr: String) -> String {
        var result = expr
        let functions: [(String, (Double) -> Double)] = [
            ("asinh", asinh), ("acosh", acosh), ("atanh", atanh),
            ("asin", asin), ("acos", acos), ("atan", atan),
            ("sinh", sinh), ("cosh", cosh), ("tanh", tanh),
            ("sin", sin), ("cos", cos), ("tan", tan),
            ("log10", log10), ("log2", log2), ("log", log10), ("ln", log),
            ("exp", exp), ("sqrt", sqrt), ("cbrt", cbrt),
            ("abs", abs), ("ceil", ceil), ("floor", floor),
            ("round", { Foundation.round($0) }),
            ("sign", { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }),
        ]

        for (name, fn) in functions {
            while let range = result.range(of: name + "(") {
                let start = range.lowerBound
                let afterParen = range.upperBound
                var depth = 1
                var end = afterParen
                while end < result.endIndex && depth > 0 {
                    if result[end] == "(" { depth += 1 }
                    if result[end] == ")" { depth -= 1 }
                    if depth > 0 { end = result.index(after: end) }
                }
                let inner = String(result[afterParen..<end])
                guard let innerVal = evaluateExpression(inner) else { break }
                let val = fn(innerVal)
                let closeEnd = end < result.endIndex ? result.index(after: end) : end
                result.replaceSubrange(start..<closeEnd, with: String(val))
            }
        }
        return result
    }

    // MARK: - Tokenizer

    private static func tokenize(_ expr: String) -> [String] {
        var tokens: [String] = []
        var num = ""
        var i = expr.startIndex
        while i < expr.endIndex {
            let ch = expr[i]
            if ch.isNumber || ch == "." ||
               (ch == "-" && (tokens.isEmpty || tokens.last == "(" || tokens.last == "^" || tokens.last == "*" || tokens.last == "/" || tokens.last == "+" || tokens.last == "-")) {
                num.append(ch)
            } else {
                if !num.isEmpty { tokens.append(num); num = "" }
                tokens.append(String(ch))
            }
            i = expr.index(after: i)
        }
        if !num.isEmpty { tokens.append(num) }
        return tokens
    }

    // MARK: - Recursive Descent Parser (with power/exponent support)

    private static func parseAddSub(tokens: [String], index: Int) -> (value: Double, nextIndex: Int)? {
        guard var left = parseMulDiv(tokens: tokens, index: index) else { return nil }
        var idx = left.nextIndex
        while idx < tokens.count && (tokens[idx] == "+" || tokens[idx] == "-") {
            let op = tokens[idx]
            guard let right = parseMulDiv(tokens: tokens, index: idx + 1) else { return nil }
            left.value = op == "+" ? left.value + right.value : left.value - right.value
            idx = right.nextIndex
        }
        return (left.value, idx)
    }

    private static func parseMulDiv(tokens: [String], index: Int) -> (value: Double, nextIndex: Int)? {
        guard var left = parsePower(tokens: tokens, index: index) else { return nil }
        var idx = left.nextIndex
        while idx < tokens.count && (tokens[idx] == "*" || tokens[idx] == "/" || tokens[idx] == "%") {
            let op = tokens[idx]
            guard let right = parsePower(tokens: tokens, index: idx + 1) else { return nil }
            if op == "*" { left.value *= right.value }
            else if op == "/" && right.value != 0 { left.value /= right.value }
            else if op == "%" { left.value = left.value.truncatingRemainder(dividingBy: right.value) }
            idx = right.nextIndex
        }
        return (left.value, idx)
    }

    private static func parsePower(tokens: [String], index: Int) -> (value: Double, nextIndex: Int)? {
        guard var base = parseFactor(tokens: tokens, index: index) else { return nil }
        var idx = base.nextIndex
        if idx < tokens.count && tokens[idx] == "^" {
            guard let exp = parsePower(tokens: tokens, index: idx + 1) else { return nil }
            base.value = pow(base.value, exp.value)
            idx = exp.nextIndex
        }
        return (base.value, idx)
    }

    private static func parseFactor(tokens: [String], index: Int) -> (value: Double, nextIndex: Int)? {
        guard index < tokens.count else { return nil }
        if tokens[index] == "(" {
            guard let inner = parseAddSub(tokens: tokens, index: index + 1) else { return nil }
            let closeIdx = inner.nextIndex
            if closeIdx < tokens.count && tokens[closeIdx] == ")" {
                return (inner.value, closeIdx + 1)
            }
            return inner
        }
        if let num = Double(tokens[index]) {
            return (num, index + 1)
        }
        return nil
    }

    // MARK: - Calculus

    /// Numerical derivative using central difference
    private static func derivative(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["deriv ", "d/dx "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.components(separatedBy: " at ")
        guard parts.count == 2, let point = evaluateExpression(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return "Usage: deriv <f(x)> at <value>"
        }
        let f = parts[0].trimmingCharacters(in: .whitespaces)
        let h = 1e-8
        guard let fp = evalF(f, x: point + h), let fm = evalF(f, x: point - h) else {
            return "Could not evaluate '\(f)'"
        }
        return "d/dx[\(f)] at x=\(formatResult(point)) = \(formatResult((fp - fm) / (2 * h)))"
    }

    /// Definite integral using adaptive Simpson's rule
    private static func integral(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["integrate ", "integral ", "int "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let tokens = cleaned.split(separator: " ").map(String.init)
        guard tokens.count >= 3,
              let a = evaluateExpression(tokens[tokens.count - 2]),
              let b = evaluateExpression(tokens[tokens.count - 1]) else {
            return "Usage: integrate <f(x)> <a> <b>"
        }
        let f = tokens.dropLast(2).joined(separator: " ")
        let n = 10000 // High precision Simpson's
        let h = (b - a) / Double(n)
        var sum = 0.0
        for i in 0...n {
            guard let fx = evalF(f, x: a + Double(i) * h) else { return "Could not evaluate '\(f)'" }
            if i == 0 || i == n { sum += fx }
            else if i % 2 == 1 { sum += 4 * fx }
            else { sum += 2 * fx }
        }
        let result = sum * h / 3.0
        return "\u{222B}[\(formatResult(a)),\(formatResult(b))] \(f) dx = \(formatResult(result))"
    }

    /// Numerical limit
    private static func limit(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["limit ", "lim "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.components(separatedBy: " at ")
        guard parts.count == 2 else { return "Usage: limit <f(x)> at <value>[+|-]" }
        let f = parts[0].trimmingCharacters(in: .whitespaces)
        var pointStr = parts[1].trimmingCharacters(in: .whitespaces)
        let fromRight = pointStr.hasSuffix("+")
        let fromLeft = pointStr.hasSuffix("-")
        if fromRight || fromLeft { pointStr = String(pointStr.dropLast()) }
        guard let point = evaluateExpression(pointStr) else { return "Invalid point '\(pointStr)'" }

        let deltas = [1e-2, 1e-4, 1e-6, 1e-8, 1e-10, 1e-12]
        var values: [Double] = []
        for d in deltas {
            let x = fromLeft ? point - d : point + d
            if let fx = evalF(f, x: x) { values.append(fx) }
        }
        guard let last = values.last else { return "Could not evaluate limit" }
        let dir = fromLeft ? "\u{207B}" : (fromRight ? "\u{207A}" : "")
        return "lim(x\u{2192}\(formatResult(point))\(dir)) \(f) = \(formatResult(last))"
    }

    /// Taylor series coefficients
    private static func taylor(_ expr: String) -> String {
        var cleaned = expr.lowercased().replacingOccurrences(of: "taylor ", with: "")
        let parts = cleaned.components(separatedBy: " at ")
        guard parts.count >= 1 else { return "Usage: taylor <f(x)> at <a> order <n>" }
        let f = parts[0].trimmingCharacters(in: .whitespaces)
        var a = 0.0
        var order = 5
        if parts.count >= 2 {
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            let restParts = rest.components(separatedBy: " order ")
            if let val = evaluateExpression(restParts[0]) { a = val }
            if restParts.count >= 2, let n = Int(restParts[1]) { order = min(n, 20) }
        }

        var coeffs: [String] = []
        let h = 1e-5
        for n in 0...order {
            let coeff = nthDerivative(f, at: a, order: n, h: h) / Double(factorialInt(n))
            if abs(coeff) > 1e-12 {
                let term: String
                if n == 0 { term = formatResult(coeff) }
                else if n == 1 { term = "\(formatResult(coeff))(x-\(formatResult(a)))" }
                else { term = "\(formatResult(coeff))(x-\(formatResult(a)))^\(n)" }
                coeffs.append(term)
            }
        }
        return "Taylor[\(f)] around x=\(formatResult(a)):\n  \(coeffs.joined(separator: " + "))"
    }

    /// Newton's method root finding
    private static func solve(_ expr: String) -> String {
        var cleaned = expr.lowercased().replacingOccurrences(of: "solve ", with: "")
        let parts = cleaned.components(separatedBy: " near ")
        let f = parts[0].trimmingCharacters(in: .whitespaces)
        var x0 = 1.0
        if parts.count >= 2, let val = evaluateExpression(parts[1]) { x0 = val }

        var x = x0
        let h = 1e-10
        for _ in 0..<100 {
            guard let fx = evalF(f, x: x),
                  let fxh = evalF(f, x: x + h) else { return "Could not evaluate '\(f)'" }
            let fprime = (fxh - fx) / h
            guard abs(fprime) > 1e-15 else { return "Derivative too small near x=\(formatResult(x))" }
            let xnew = x - fx / fprime
            if abs(xnew - x) < 1e-12 {
                return "Root of \(f) = 0: x = \(formatResult(xnew))"
            }
            x = xnew
        }
        return "Newton's method did not converge from x0=\(formatResult(x0)). Try a different starting point."
    }

    // MARK: - Statistics

    private static func stats(_ expr: String, op: String) -> String {
        let nums = parseNumbers(from: expr)
        guard !nums.isEmpty else { return "Provide numbers: \(op) 1 2 3 4 5" }
        let n = Double(nums.count)

        switch op {
        case "mean":
            return formatResult(nums.reduce(0, +) / n)
        case "median":
            let sorted = nums.sorted()
            let mid = nums.count / 2
            let median = nums.count % 2 == 0 ? (sorted[mid-1] + sorted[mid]) / 2 : sorted[mid]
            return formatResult(median)
        case "stdev":
            let mean = nums.reduce(0, +) / n
            let variance = nums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
            return formatResult(sqrt(variance))
        case "variance":
            let mean = nums.reduce(0, +) / n
            return formatResult(nums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n)
        case "sum":
            return formatResult(nums.reduce(0, +))
        case "product":
            return formatResult(nums.reduce(1, *))
        default:
            return "Unknown operation"
        }
    }

    // MARK: - Number Theory

    private static func factor(_ expr: String) -> String {
        guard let firstNum = parseNumbers(from: expr).first, let n = Int(exactly: firstNum), n > 1 else { return "Provide a positive integer > 1" }
        var factors: [Int] = []
        var num = n
        var d = 2
        while d * d <= num {
            while num % d == 0 { factors.append(d); num /= d }
            d += 1
        }
        if num > 1 { factors.append(num) }

        // Group
        var grouped: [(Int, Int)] = []
        for f in factors {
            if grouped.last?.0 == f { grouped[grouped.count-1].1 += 1 }
            else { grouped.append((f, 1)) }
        }
        let formatted = grouped.map { $0.1 == 1 ? "\($0.0)" : "\($0.0)^\($0.1)" }.joined(separator: " \u{00D7} ")
        return "\(n) = \(formatted)"
    }

    private static func gcdCalc(_ expr: String) -> String {
        let nums = parseNumbers(from: expr).map { Int($0) }
        guard nums.count >= 2 else { return "Provide at least 2 numbers" }
        var result = nums[0]
        for i in 1..<nums.count { result = gcdInt(result, nums[i]) }
        return "gcd = \(result)"
    }

    private static func lcmCalc(_ expr: String) -> String {
        let nums = parseNumbers(from: expr).map { Int($0) }
        guard nums.count >= 2 else { return "Provide at least 2 numbers" }
        var result = nums[0]
        for i in 1..<nums.count { result = result / gcdInt(result, nums[i]) * nums[i] }
        return "lcm = \(result)"
    }

    private static func isPrime(_ expr: String) -> String {
        guard let firstNum = parseNumbers(from: expr).first, let n = Int(exactly: firstNum), n > 0 else { return "Provide a positive integer" }
        if n < 2 { return "\(n) is not prime" }
        if n < 4 { return "\(n) is prime" }
        if n % 2 == 0 { return "\(n) is not prime (divisible by 2)" }
        var i = 3
        while i * i <= n { if n % i == 0 { return "\(n) is not prime (divisible by \(i))" }; i += 2 }
        return "\(n) is prime"
    }

    private static func fibonacci(_ expr: String) -> String {
        guard let firstNum = parseNumbers(from: expr).first, let n = Int(exactly: firstNum), n >= 0, n <= 90 else { return "Provide n (0-90)" }
        if n <= 1 { return "fib(\(n)) = \(n)" }
        var a = 0, b = 1
        for _ in 2...n { let t = a + b; a = b; b = t }
        return "fib(\(n)) = \(b)"
    }

    private static func combination(_ expr: String) -> String {
        let nums = parseNumbers(from: expr).map { Int($0) }
        guard nums.count >= 2, nums[0] >= nums[1], nums[1] >= 0 else { return "Provide n k where n >= k >= 0" }
        return "C(\(nums[0]),\(nums[1])) = \(comb(nums[0], nums[1]))"
    }

    private static func permutation(_ expr: String) -> String {
        let nums = parseNumbers(from: expr).map { Int($0) }
        guard nums.count >= 2, nums[0] >= nums[1], nums[1] >= 0 else { return "Provide n k" }
        return "P(\(nums[0]),\(nums[1])) = \(factorialInt(nums[0]) / factorialInt(nums[0] - nums[1]))"
    }

    private static func factorial(_ expr: String) -> String {
        guard let firstNum = parseNumbers(from: expr).first, let n = Int(exactly: firstNum), n >= 0, n <= 20 else { return "Provide n (0-20)" }
        return "\(n)! = \(factorialInt(n))"
    }

    // MARK: - Linear Algebra

    private static func determinant(_ expr: String) -> String {
        // Parse [[a,b],[c,d]]
        let cleaned = expr.lowercased().replacingOccurrences(of: "det ", with: "")
        guard let matrix = parseMatrix(cleaned) else { return "Usage: det [[1,2],[3,4]]" }
        guard matrix.count == matrix[0].count else { return "Matrix must be square" }
        return "det = \(formatResult(det(matrix)))"
    }

    // MARK: - Unit Conversion

    private static func unitConversion(_ expr: String) -> String? {
        let parts = expr.components(separatedBy: " to ")
        guard parts.count == 2 else { return nil }
        let from = parts[0].trimmingCharacters(in: .whitespaces)
        let to = parts[1].trimmingCharacters(in: .whitespaces)

        let numStr = from.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
        guard let value = Double(numStr) else { return nil }
        let unit = from.dropFirst(numStr.count).trimmingCharacters(in: .whitespaces).lowercased()

        let conversions: [(Set<String>, Set<String>, (Double) -> Double, String)] = [
            (["f", "fahrenheit"], ["c", "celsius"], { ($0 - 32) * 5/9 }, "\u{00B0}C"),
            (["c", "celsius"], ["f", "fahrenheit"], { $0 * 9/5 + 32 }, "\u{00B0}F"),
            (["km"], ["miles", "mi"], { $0 * 0.621371 }, "mi"),
            (["miles", "mi"], ["km"], { $0 * 1.60934 }, "km"),
            (["lb", "lbs", "pounds"], ["kg"], { $0 * 0.453592 }, "kg"),
            (["kg"], ["lb", "lbs", "pounds"], { $0 * 2.20462 }, "lb"),
            (["m", "meters"], ["ft", "feet"], { $0 * 3.28084 }, "ft"),
            (["ft", "feet"], ["m", "meters"], { $0 * 0.3048 }, "m"),
            (["in", "inches"], ["cm"], { $0 * 2.54 }, "cm"),
            (["cm"], ["in", "inches"], { $0 / 2.54 }, "in"),
            (["gal", "gallons"], ["l", "liters"], { $0 * 3.78541 }, "L"),
            (["l", "liters"], ["gal", "gallons"], { $0 / 3.78541 }, "gal"),
            (["deg", "degrees"], ["rad", "radians"], { $0 * .pi / 180 }, "rad"),
            (["rad", "radians"], ["deg", "degrees"], { $0 * 180 / .pi }, "\u{00B0}"),
            (["oz"], ["g", "grams"], { $0 * 28.3495 }, "g"),
            (["g", "grams"], ["oz"], { $0 / 28.3495 }, "oz"),
        ]

        for (fromUnits, toUnits, convert, label) in conversions {
            if fromUnits.contains(unit) && toUnits.contains(to) {
                return "\(value) \(unit) = \(formatResult(convert(value))) \(label)"
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func evalF(_ expr: String, x: Double) -> Double? {
        // Replace standalone 'x' only, not 'x' inside function names like 'exp', 'max'
        let substituted = expr.replacingOccurrences(
            of: "(?<![a-z])x(?![a-z])",
            with: "(\(x))",
            options: .regularExpression
        )
        return evaluateExpression(substituted)
    }

    private static func nthDerivative(_ f: String, at a: Double, order: Int, h: Double) -> Double {
        if order == 0 { return evalF(f, x: a) ?? 0 }
        let hp = h * Double(order)
        return (nthDerivative(f, at: a + hp, order: order - 1, h: h) - nthDerivative(f, at: a - hp, order: order - 1, h: h)) / (2 * hp)
    }

    private static func factorialInt(_ n: Int) -> Int {
        n <= 1 ? 1 : (1...n).reduce(1, *)
    }

    private static func comb(_ n: Int, _ k: Int) -> Int {
        if k == 0 || k == n { return 1 }
        return comb(n-1, k-1) + comb(n-1, k)
    }

    private static func gcdInt(_ a: Int, _ b: Int) -> Int {
        b == 0 ? abs(a) : gcdInt(b, a % b)
    }

    private static func parseNumbers(from expr: String) -> [Double] {
        let parts = expr.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" })
        return parts.compactMap { Double($0) }
    }

    private static func parseMatrix(_ expr: String) -> [[Double]]? {
        let cleaned = expr.replacingOccurrences(of: " ", with: "")
        guard cleaned.hasPrefix("[[") && cleaned.hasSuffix("]]") else { return nil }
        let inner = String(cleaned.dropFirst(1).dropLast(1))
        let rows = inner.components(separatedBy: "],[")
        return rows.map { row in
            row.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                .split(separator: ",").compactMap { Double($0) }
        }
    }

    private static func det(_ m: [[Double]]) -> Double {
        let n = m.count
        if n == 1 { return m[0][0] }
        if n == 2 { return m[0][0] * m[1][1] - m[0][1] * m[1][0] }
        var result = 0.0
        for j in 0..<n {
            let minor = (1..<n).map { i in
                (0..<n).filter { $0 != j }.map { m[i][$0] }
            }
            result += (j % 2 == 0 ? 1 : -1) * m[0][j] * det(minor)
        }
        return result
    }

    static func formatResult(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "\u{221E}" : "-\u{221E}" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.10g", value)
    }

    // MARK: - Real Analysis

    /// Partial sums of a series: series 1/n^2 20 (first 20 terms)
    private static func series(_ expr: String) -> String {
        var cleaned = expr.lowercased().replacingOccurrences(of: "series ", with: "")
        let parts = cleaned.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return "Usage: series <f(n)> [terms]\nExample: series 1/n^2 100" }
        let terms = parts.count >= 2 ? (Int(parts.last!) ?? 20) : 20
        let f = parts.count >= 2 ? parts.dropLast().joined(separator: " ") : parts[0]

        var partialSums: [Double] = []
        var total = 0.0
        for n in 1...terms {
            let substituted = f.replacingOccurrences(
                of: "(?<![a-z])n(?![a-z])", with: "(\(n))", options: .regularExpression)
            guard let val = evaluateExpression(substituted) else {
                return "Could not evaluate term at n=\(n)"
            }
            total += val
            if n <= 10 || n == terms { partialSums.append(total) }
        }
        var lines = ["\u{2211}(n=1..\(terms)) \(f)"]
        for (i, s) in partialSums.enumerated() {
            let n = i < 10 ? i + 1 : terms
            lines.append("  S(\(n)) = \(formatResult(s))")
        }
        lines.append("Sum = \(formatResult(total))")
        return lines.joined(separator: "\n")
    }

    /// Test series convergence: converges 1/n^2
    private static func convergence(_ expr: String) -> String {
        var f = expr.lowercased()
        for prefix in ["converges ", "convergence "] {
            if f.hasPrefix(prefix) { f = String(f.dropFirst(prefix.count)); break }
        }
        f = f.trimmingCharacters(in: .whitespaces)

        // Compute ratio test: lim |a(n+1)/a(n)|
        var ratios: [Double] = []
        for n in 10...50 {
            let an = f.replacingOccurrences(of: "(?<![a-z])n(?![a-z])", with: "(\(n))", options: .regularExpression)
            let an1 = f.replacingOccurrences(of: "(?<![a-z])n(?![a-z])", with: "(\(n+1))", options: .regularExpression)
            guard let vn = evaluateExpression(an), let vn1 = evaluateExpression(an1), vn != 0 else { continue }
            ratios.append(abs(vn1 / vn))
        }

        let avgRatio = ratios.isEmpty ? 1.0 : ratios.reduce(0, +) / Double(ratios.count)

        // Also compute partial sums to check
        var sum100 = 0.0, sum1000 = 0.0
        for n in 1...1000 {
            let sub = f.replacingOccurrences(of: "(?<![a-z])n(?![a-z])", with: "(\(n))", options: .regularExpression)
            if let val = evaluateExpression(sub) {
                if n <= 100 { sum100 += val }
                sum1000 += val
            }
        }

        var lines = ["Series \u{2211} \(f):"]
        lines.append("  Ratio test: lim|a(n+1)/a(n)| \u{2248} \(formatResult(avgRatio))")
        if avgRatio < 1 - 1e-6 {
            lines.append("  Ratio < 1 \u{2192} CONVERGES (absolutely)")
        } else if avgRatio > 1 + 1e-6 {
            lines.append("  Ratio > 1 \u{2192} DIVERGES")
        } else {
            lines.append("  Ratio \u{2248} 1 \u{2192} INCONCLUSIVE (ratio test)")
        }
        lines.append("  S(100)  = \(formatResult(sum100))")
        lines.append("  S(1000) = \(formatResult(sum1000))")
        if abs(sum1000 - sum100) < abs(sum100) * 0.01 {
            lines.append("  Partial sums stabilizing \u{2192} likely converges")
        }
        return lines.joined(separator: "\n")
    }

    /// Test continuity at a point: continuous x^2 at 2
    private static func continuity(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["continuous ", "continuity "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.components(separatedBy: " at ")
        guard parts.count == 2, let point = evaluateExpression(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return "Usage: continuous <f(x)> at <value>"
        }
        let f = parts[0].trimmingCharacters(in: .whitespaces)

        let fx = evalF(f, x: point)
        let leftLim = evalF(f, x: point - 1e-10)
        let rightLim = evalF(f, x: point + 1e-10)

        var lines = ["Continuity of \(f) at x=\(formatResult(point)):"]
        if let v = fx { lines.append("  f(\(formatResult(point))) = \(formatResult(v))") }
        else { lines.append("  f(\(formatResult(point))) = undefined") }
        if let l = leftLim { lines.append("  lim(x\u{2192}\(formatResult(point))\u{207B}) = \(formatResult(l))") }
        if let r = rightLim { lines.append("  lim(x\u{2192}\(formatResult(point))\u{207A}) = \(formatResult(r))") }

        if let v = fx, let l = leftLim, let r = rightLim {
            if abs(l - r) < 1e-6 && abs(v - l) < 1e-6 {
                lines.append("  \u{2713} CONTINUOUS at x=\(formatResult(point))")
            } else if abs(l - r) < 1e-6 {
                lines.append("  \u{2717} REMOVABLE DISCONTINUITY (limit exists but \u{2260} f(x))")
            } else {
                lines.append("  \u{2717} JUMP DISCONTINUITY (left \u{2260} right limit)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Riemann sum: riemann x^2 0 1 left 10
    private static func riemann(_ expr: String) -> String {
        var cleaned = expr.lowercased().replacingOccurrences(of: "riemann ", with: "")
        let parts = cleaned.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return "Usage: riemann <f(x)> <a> <b> [left|right|mid] [n]" }

        let method = parts.count >= 4 ? parts[parts.count - 2] : "mid"
        let n = parts.count >= 5 ? (Int(parts.last!) ?? 10) : (parts.count >= 4 && Int(parts.last!) != nil ? Int(parts.last!)! : 10)
        let b = evaluateExpression(parts.count >= 5 ? parts[parts.count - 3] : parts[parts.count - 1]) ?? 1
        let a = evaluateExpression(parts.count >= 5 ? parts[parts.count - 4] : parts[parts.count - 2]) ?? 0
        let f = parts.count >= 5 ? parts.dropLast(4).joined(separator: " ")
            : (parts.count >= 4 ? parts.dropLast(3).joined(separator: " ")
            : parts.dropLast(2).joined(separator: " "))

        let dx = (b - a) / Double(n)
        var sum = 0.0
        for i in 0..<n {
            let x: Double
            switch method {
            case "left": x = a + Double(i) * dx
            case "right": x = a + Double(i + 1) * dx
            default: x = a + (Double(i) + 0.5) * dx // midpoint
            }
            if let fx = evalF(f, x: x) { sum += fx * dx }
        }

        return "Riemann(\(method), n=\(n)) \u{222B}[\(formatResult(a)),\(formatResult(b))] \(f) dx = \(formatResult(sum))"
    }

    /// Generate sequence terms: sequence 1/n 10
    private static func sequence(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["sequence ", "seq "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.split(separator: " ").map(String.init)
        let terms = parts.count >= 2 ? (Int(parts.last!) ?? 10) : 10
        let f = parts.count >= 2 ? parts.dropLast().joined(separator: " ") : parts.joined(separator: " ")

        var values: [String] = ["Sequence a(n) = \(f):"]
        for n in 1...min(terms, 20) {
            let sub = f.replacingOccurrences(of: "(?<![a-z])n(?![a-z])", with: "(\(n))", options: .regularExpression)
            if let val = evaluateExpression(sub) {
                values.append("  a(\(n)) = \(formatResult(val))")
            }
        }
        // Check if converging
        let lastSub = f.replacingOccurrences(of: "(?<![a-z])n(?![a-z])", with: "(10000)", options: .regularExpression)
        if let limit = evaluateExpression(lastSub) {
            values.append("  a(10000) \u{2248} \(formatResult(limit)) (approximate limit)")
        }
        return values.joined(separator: "\n")
    }

    /// Supremum of f(x) on an interval: supremum sin(x) 0 pi
    private static func supremum(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["supremum ", "sup "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.split(separator: " ").map(String.init)
        guard parts.count >= 3, let a = evaluateExpression(parts[parts.count-2]),
              let b = evaluateExpression(parts[parts.count-1]) else {
            return "Usage: supremum <f(x)> <a> <b>"
        }
        let f = parts.dropLast(2).joined(separator: " ")
        var maxVal = -Double.infinity
        var maxX = a
        let steps = 10000
        for i in 0...steps {
            let x = a + (b - a) * Double(i) / Double(steps)
            if let fx = evalF(f, x: x), fx > maxVal { maxVal = fx; maxX = x }
        }
        return "sup{\(f)} on [\(formatResult(a)),\(formatResult(b))] = \(formatResult(maxVal)) at x\u{2248}\(formatResult(maxX))"
    }

    /// Infimum
    private static func infimum(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["infimum ", "inf "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.split(separator: " ").map(String.init)
        guard parts.count >= 3, let a = evaluateExpression(parts[parts.count-2]),
              let b = evaluateExpression(parts[parts.count-1]) else {
            return "Usage: infimum <f(x)> <a> <b>"
        }
        let f = parts.dropLast(2).joined(separator: " ")
        var minVal = Double.infinity
        var minX = a
        let steps = 10000
        for i in 0...steps {
            let x = a + (b - a) * Double(i) / Double(steps)
            if let fx = evalF(f, x: x), fx < minVal { minVal = fx; minX = x }
        }
        return "inf{\(f)} on [\(formatResult(a)),\(formatResult(b))] = \(formatResult(minVal)) at x\u{2248}\(formatResult(minX))"
    }

    // MARK: - Graph Theory

    /// Parse adjacency matrix and compute vertex degrees
    private static func graphDegree(_ expr: String) -> String {
        let cleaned = expr.lowercased().replacingOccurrences(of: "degree ", with: "")
        guard let matrix = parseMatrix(cleaned) else { return "Usage: degree [[0,1,1],[1,0,1],[1,1,0]]" }
        let degrees = matrix.map { row in Int(row.reduce(0, +)) }
        let lines = degrees.enumerated().map { "  v\($0.offset): degree \($0.element)" }
        return "Vertex degrees:\n" + lines.joined(separator: "\n") +
               "\n  Sum of degrees: \(degrees.reduce(0, +))" +
               "\n  Number of edges: \(degrees.reduce(0, +) / 2)"
    }

    /// Check adjacency: adjacent [[0,1],[1,0]] 0 1
    private static func graphAdjacent(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["adjacent ", "adj "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        let parts = cleaned.components(separatedBy: "]]")
        guard parts.count >= 2, let matrix = parseMatrix(parts[0] + "]]") else {
            return "Usage: adjacent [[0,1],[1,0]] <v1> <v2>"
        }
        let rest = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard rest.count >= 2, let v1 = Int(rest[0]), let v2 = Int(rest[1]),
              v1 < matrix.count, v2 < matrix[0].count else {
            return "Provide valid vertex indices"
        }
        return matrix[v1][v2] > 0 ? "v\(v1) and v\(v2) ARE adjacent" : "v\(v1) and v\(v2) are NOT adjacent"
    }

    /// Check if Eulerian path/circuit exists
    private static func graphEuler(_ expr: String) -> String {
        let cleaned = expr.lowercased().replacingOccurrences(of: "euler ", with: "")
        guard let matrix = parseMatrix(cleaned) else { return "Usage: euler [[0,1,1],[1,0,1],[1,1,0]]" }
        let degrees = matrix.map { Int($0.reduce(0, +)) }
        let oddDegrees = degrees.filter { $0 % 2 != 0 }.count

        if oddDegrees == 0 { return "Euler CIRCUIT exists (all vertices have even degree)" }
        if oddDegrees == 2 { return "Euler PATH exists (exactly 2 vertices with odd degree)" }
        return "No Euler path or circuit (\(oddDegrees) vertices with odd degree)"
    }

    /// Shortest path (BFS on unweighted adjacency matrix)
    private static func graphPath(_ expr: String) -> String {
        let cleaned = expr.lowercased().replacingOccurrences(of: "path ", with: "")
        let parts = cleaned.components(separatedBy: "]]")
        guard parts.count >= 2, let matrix = parseMatrix(parts[0] + "]]") else {
            return "Usage: path [[0,1,0],[1,0,1],[0,1,0]] <from> <to>"
        }
        let rest = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard rest.count >= 2, let from = Int(rest[0]), let to = Int(rest[1]) else {
            return "Provide from and to vertices"
        }
        let n = matrix.count
        var dist = Array(repeating: -1, count: n)
        var prev = Array(repeating: -1, count: n)
        dist[from] = 0
        var queue = [from]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if v == to { break }
            for u in 0..<n where matrix[v][u] > 0 && dist[u] == -1 {
                dist[u] = dist[v] + 1
                prev[u] = v
                queue.append(u)
            }
        }
        if dist[to] == -1 { return "No path from v\(from) to v\(to)" }
        var path: [Int] = []
        var cur = to
        while cur != -1 { path.insert(cur, at: 0); cur = prev[cur] }
        return "Shortest path v\(from)\u{2192}v\(to): \(path.map{"v\($0)"}.joined(separator: "\u{2192}")) (length \(dist[to]))"
    }

    /// Chromatic number (greedy upper bound)
    private static func graphChromatic(_ expr: String) -> String {
        let cleaned = expr.lowercased().replacingOccurrences(of: "chromatic ", with: "")
        guard let matrix = parseMatrix(cleaned) else { return "Usage: chromatic [[0,1,1],[1,0,1],[1,1,0]]" }
        let n = matrix.count
        var colors = Array(repeating: -1, count: n)
        for v in 0..<n {
            var used: Set<Int> = []
            for u in 0..<n where matrix[v][u] > 0 && colors[u] >= 0 { used.insert(colors[u]) }
            var c = 0
            while used.contains(c) { c += 1 }
            colors[v] = c
        }
        let chromatic = (colors.max() ?? 0) + 1
        let coloring = colors.enumerated().map { "v\($0.offset)=c\($0.element)" }.joined(separator: ", ")
        return "Chromatic number \u{2264} \(chromatic) (greedy)\nColoring: \(coloring)"
    }

    // MARK: - Additional Linear Algebra

    private static func trace(_ expr: String) -> String {
        let cleaned = expr.lowercased().replacingOccurrences(of: "trace ", with: "")
        guard let matrix = parseMatrix(cleaned) else { return "Usage: trace [[1,2],[3,4]]" }
        let n = min(matrix.count, matrix[0].count)
        let tr = (0..<n).map { matrix[$0][$0] }.reduce(0, +)
        return "tr = \(formatResult(tr))"
    }

    private static func transpose(_ expr: String) -> String {
        let cleaned = expr.lowercased().replacingOccurrences(of: "transpose ", with: "")
        guard let matrix = parseMatrix(cleaned) else { return "Usage: transpose [[1,2],[3,4]]" }
        let rows = matrix.count, cols = matrix[0].count
        var result: [[Double]] = Array(repeating: Array(repeating: 0, count: rows), count: cols)
        for i in 0..<rows { for j in 0..<cols { result[j][i] = matrix[i][j] } }
        let formatted = result.map { "[\($0.map { formatResult($0) }.joined(separator: ","))]" }
        return "[\(formatted.joined(separator: ","))]"
    }

    /// Eigenvalues for 2x2 matrix using quadratic formula
    private static func eigenvalues2x2(_ expr: String) -> String {
        var cleaned = expr.lowercased()
        for prefix in ["eigenvalues ", "eigen "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        guard let m = parseMatrix(cleaned), m.count == 2, m[0].count == 2 else {
            return "Usage: eigenvalues [[a,b],[c,d]] (2x2 only)"
        }
        let a = m[0][0], b = m[0][1], c = m[1][0], d = m[1][1]
        let tr = a + d
        let det = a * d - b * c
        let disc = tr * tr - 4 * det
        if disc >= 0 {
            let l1 = (tr + sqrt(disc)) / 2
            let l2 = (tr - sqrt(disc)) / 2
            return "\u{03BB}\u{2081} = \(formatResult(l1)), \u{03BB}\u{2082} = \(formatResult(l2))"
        } else {
            let real = tr / 2
            let imag = sqrt(-disc) / 2
            return "\u{03BB} = \(formatResult(real)) \u{00B1} \(formatResult(imag))i"
        }
    }
}
