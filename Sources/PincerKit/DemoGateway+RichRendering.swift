import Foundation

/// The demo's "Rate limiter design" chat: an agent answering with a Mermaid flowchart, a sequence
/// diagram and display math, which the transcript draws natively (#40).
extension DemoGateway {
    static let richRenderingKey = "agent:main:dashboard:rate-limiter"
    static let richRenderingTitle = "Rate limiter design"
    static let richRenderingPreview = "The bucket refills at r tokens per second, up to b."

    static let richRenderingFlowchart = """
    flowchart TD
        A[Request arrives] --> B{Tokens left?}
        B -->|Yes| C[Take a token]
        C --> D[Forward to API]
        B -->|No| E[Return 429]
        E --> F([Client backs off])
        F -.-> A
    """

    static let richRenderingSequence = """
    sequenceDiagram
        participant C as Client
        participant L as Limiter
        participant A as API
        C->>L: GET /orders
        L->>L: refill(now)
        alt bucket has a token
            L->>A: forward
            A-->>C: 200 OK
        else empty
            L-->>C: 429 Retry-After: 2
        end
    """

    static let richRenderingMath = #"""
    T(t) = \min\left(b,\; T_0 + r\,(t - t_0)\right)
    """#

    static let richRenderingBurst = #"""
    \text{max burst} = b + r\,\Delta t, \qquad \bar{\lambda} \le \frac{b}{\Delta t} + r
    """#

    static let richRenderingHTML = """
    <div style="font-family: -apple-system, sans-serif; max-width: 420px; margin: 24px auto; padding: 20px;
                border: 1px solid #e5484d; border-radius: 12px; background: #fff5f5; color: #1d1d1f">
      <h2 style="margin: 0 0 8px; color: #c62a2f">Slow down a little</h2>
      <p style="margin: 0 0 12px">You've sent more requests than your plan allows. Try again in <b>2 seconds</b>.</p>
      <code style="font-size: 12px; color: #6e6e73">HTTP 429 · Retry-After: 2</code>
    </div>
    """

    static func seedRichRenderingTranscript() -> [JSONValue] {
        let minute = 60.0
        return [
            Self.message("user", [Self.text("""
            Sketch how the API rate limiter should work: the request flow, what the client sees, and the refill math.
            """)], ago: 9 * minute),
            Self.message("assistant", [Self.text("""
            A token bucket per API key. Each request takes a token; an empty bucket answers 429 and the client backs off.

            ```mermaid
            \(Self.richRenderingFlowchart)
            ```

            What the client sees when the bucket runs dry:

            ```mermaid
            \(Self.richRenderingSequence)
            ```

            The bucket refills at *r* tokens per second, up to a capacity *b*:

            $$
            \(Self.richRenderingMath)
            $$

            So the largest burst in a window Δ*t*, and the sustained rate it allows, are

            $$
            \(Self.richRenderingBurst)
            $$

            And the page a browser shows on a 429:

            ```html
            \(Self.richRenderingHTML)
            ```
            """)], ago: 8 * minute),
        ]
    }
}
