def binary_metrics(predicted_ids, goal_ids):
    predicted = set(predicted_ids)
    goals = set(goal_ids)
    true_positive = len(predicted & goals)
    false_positive = len(predicted - goals)
    false_negative = len(goals - predicted)
    return {
        "true_positive": true_positive,
        "false_positive": false_positive,
        "false_negative": false_negative,
        "precision": true_positive / len(predicted) if predicted else 0.0,
        "recall": true_positive / len(goals) if goals else 0.0,
    }
