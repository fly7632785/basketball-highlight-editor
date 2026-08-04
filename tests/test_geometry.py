import unittest

from basketball_highlight.geometry import crossing_x_at_y, is_rim_crossing


class GeometryTest(unittest.TestCase):
    def test_crossing_x_is_interpolated_at_rim_height(self):
        x = crossing_x_at_y({"x": 480, "y": 300}, {"x": 500, "y": 350}, 325)
        self.assertEqual(x, 490)

    def test_upward_or_flat_motion_is_not_a_downward_crossing(self):
        self.assertIsNone(crossing_x_at_y({"x": 480, "y": 330}, {"x": 500, "y": 320}, 325))

    def test_crossing_must_be_inside_rim_corridor(self):
        self.assertTrue(is_rim_crossing(490, 480, 500, 5))
        self.assertFalse(is_rim_crossing(510, 480, 500, 5))


if __name__ == "__main__":
    unittest.main()
