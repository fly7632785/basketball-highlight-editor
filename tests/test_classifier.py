import unittest

import numpy as np

from basketball_highlight.classifier import fit_logistic, predict_proba


class ClassifierTest(unittest.TestCase):
    def test_fit_logistic_separates_training_examples(self):
        x = np.asarray([[0.0], [0.2], [0.8], [1.0]], dtype=float)
        y = np.asarray([0, 0, 1, 1], dtype=float)
        model = fit_logistic(x, y, steps=500)
        probabilities = predict_proba(model, x)
        self.assertLess(probabilities[0], 0.5)
        self.assertGreater(probabilities[-1], 0.5)

    def test_fit_logistic_handles_constant_feature(self):
        x = np.ones((4, 2), dtype=float)
        y = np.asarray([0, 0, 1, 1], dtype=float)
        model = fit_logistic(x, y, steps=50)
        probabilities = predict_proba(model, x)
        self.assertEqual(len(probabilities), 4)
        self.assertTrue(np.all(np.isfinite(probabilities)))


if __name__ == "__main__":
    unittest.main()
