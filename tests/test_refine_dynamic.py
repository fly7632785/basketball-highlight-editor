import unittest

from refine_dynamic_candidates import merge_scan_windows


class RefineDynamicTest(unittest.TestCase):
    def test_merge_scan_windows_combines_overlapping_candidate_windows(self):
        result = merge_scan_windows([10.0, 12.0, 30.0], window=2.5)
        self.assertEqual([item["indices"] for item in result], [[0, 1], [2]])
        self.assertAlmostEqual(result[0]["start"], 7.5)
        self.assertAlmostEqual(result[0]["end"], 14.5)


if __name__ == "__main__":
    unittest.main()
