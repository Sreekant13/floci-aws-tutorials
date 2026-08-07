"""
One step of a workflow, as a Lambda.

Step Functions calls this as a Task state. Whatever a Task returns becomes the
input to the next state, so the shape of the return value is part of the
workflow contract, not just this function's business.

Raising is how a Task reports failure. Step Functions then consults the Retry
and Catch blocks attached to that state.
"""


def handler(event, context):
    order_id = event.get("orderId", "unknown")
    total = event.get("total", 0)

    # Logged BEFORE validating, so every attempt leaves a trace even when the
    # call goes on to fail. Counting these lines is how section 5 of the README
    # proves whether Step Functions actually retried, rather than taking the
    # Retry block at its word.
    print(f"charge attempt for order {order_id}, total {total}")

    # A Task that raises is a failed state, which is what Retry and Catch react
    # to. This is the hook the tutorial uses to demonstrate error handling.
    if total < 0:
        raise ValueError(f"cannot charge a negative total: {total}")

    print(f"charging order {order_id} for {total}")

    # Merge rather than replace. The next state usually still needs the fields
    # that arrived, and silently dropping them is a common workflow bug.
    return {**event, "charged": True, "status": "PAID"}
