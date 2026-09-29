import numpy as np


def softmax(x):
    """Turn a vector of scores into probabilities that sum to 1."""
    z = x - x.max()
    e = np.exp(z)
    return e / e.sum()


scores = np.array([1000.0, 1001.0, 1002.0])
print(softmax(scores))
