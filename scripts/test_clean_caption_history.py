"""Deterministic cleanup tests; no model download."""

import unittest

from clean_caption_history import collapse_restarts, detect_lang


class DetectLangTests(unittest.TestCase):
    def test_three_languages(self):
        self.assertEqual(detect_lang("안녕하세요 잘 지내십니까?"), "ko")
        self.assertEqual(detect_lang("How have you been today?"), "en")
        self.assertEqual(detect_lang("ช่วยฉันเรียนรู้"), "th")

    def test_mixed_hangul_wins(self):
        self.assertEqual(detect_lang("오늘은 AI 공부하고 있습니다"), "ko")


class CollapseTests(unittest.TestCase):
    def test_exact_repeats(self):
        self.assertEqual(
            collapse_restarts("How old are you today? How old are you today? How old are you today?"),
            "How old are you today?",
        )

    def test_growing_korean_draft(self):
        text = (
            "오늘은 몇 살? 오늘은 몇 살이 되는? 오늘은 몇 살이 되는까요?"
        )
        self.assertEqual(collapse_restarts(text), "오늘은 몇 살이 되는까요?")

    def test_strips_stop(self):
        text = "How have you been doing? Stop. Hello How are you all doing? Stop."
        cleaned = collapse_restarts(text)
        self.assertNotIn("Stop", cleaned)
        self.assertIn("How are you all doing?", cleaned)

    def test_keeps_new_clause(self):
        text = "안녕하세요 잘 지내십니까? 내 이름 이승입니다."
        self.assertEqual(collapse_restarts(text), text)


if __name__ == "__main__":
    unittest.main()
