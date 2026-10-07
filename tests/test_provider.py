"""Tests for Gipformer Captions: run the entrypoint the way BashCut does, in GIPFORMER_FAKE mode (no model).

    python3 -m unittest discover -s tests -v

Build first when the plugin has a build.sh. These tests use only the Python standard library and are not shipped.
"""
import json
import os
import pathlib
import random
import struct
import subprocess
import tempfile
import wave
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / "plugin.json").read_text())
ENTRYPOINT = ROOT / MANIFEST["entrypoint"]


def environment(folder):
    """The filtered environment BashCut gives plugin processes."""
    data, cache = pathlib.Path(folder, "data"), pathlib.Path(folder, "cache")
    data.mkdir(exist_ok=True)
    cache.mkdir(exist_ok=True)
    env = {key: os.environ[key] for key in ("HOME", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
    env.update({
        "GIPFORMER_FAKE": "1",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "BASHCUT_PLUGIN_ID": MANIFEST["id"],
        "BASHCUT_PLUGIN_DIR": str(ROOT),
        "BASHCUT_PLUGIN_API_VERSION": str(MANIFEST["apiVersion"]),
        "BASHCUT_PLUGIN_DATA": str(data),
        "BASHCUT_PLUGIN_CACHE": str(cache),
    })
    return env


def rpc(folder, method, params, provider=None):
    """One request over the one-shot transport (`provider rpc`)."""
    request = {"id": "r1", "apiVersion": MANIFEST["apiVersion"], "method": method, "params": params}
    if provider:
        request["provider"] = provider
    out = subprocess.run([str(ENTRYPOINT), "rpc"], input=json.dumps(request) + "\n", capture_output=True, text=True,
                         cwd=ROOT, env=environment(folder), timeout=60)
    if out.returncode != 0:
        raise AssertionError(f"exit {out.returncode}: {out.stderr}")
    response = json.loads(out.stdout)
    if response.get("id") != "r1":
        raise AssertionError(f"the response id does not match: {out.stdout}")
    return response


class Session:
    """The session transport (`provider session`): newline-delimited JSON in both directions."""

    def __init__(self, folder):
        self.process = subprocess.Popen([str(ENTRYPOINT), "session"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, cwd=ROOT, env=environment(folder))
        self.send({"type": "hello", "apiVersion": MANIFEST["apiVersion"], "host": "BashCut", "pluginId": MANIFEST["id"]})
        hello = self.read()
        if hello.get("type") != "hello":
            raise AssertionError(f"expected hello, got {hello}")

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def read(self):
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError(f"the session ended: {self.process.stderr.read()}")
        return json.loads(line)

    def request(self, request_id, method, params, provider=None, on_call=None):
        """Sends a request and returns (lines before the reply, reply). `on_call(call)` answers host calls."""
        request = {"type": "request", "id": request_id, "apiVersion": MANIFEST["apiVersion"], "method": method,
                   "params": params}
        if provider:
            request["provider"] = provider
        self.send(request)
        lines = []
        while True:
            message = self.read()
            if message.get("type") == "call" and on_call:
                self.send({"type": "callResult", "callId": message["callId"], **on_call(message)})
            if message.get("type") in ("progress", "event", "call"):
                lines.append(message)
                continue
            if message.get("id") != request_id:
                raise AssertionError(f"reply for another request: {message}")
            return lines, message

    def close(self):
        self.send({"type": "shutdown"})
        self.process.wait(timeout=10)
        self.process.stdout.close()
        self.process.stderr.close()
        self.process.stdin.close()


def call(folder, method, params, provider=None):
    """One request over the plugin's own transport; returns the response."""
    if MANIFEST.get("transport") != "session":
        return rpc(folder, method, params, provider)
    session = Session(folder)
    try:
        return session.request("r1", method, params, provider)[1]
    finally:
        session.close()


PROVIDER = "bashcut.gipformer-captions.local"


def make_audio(folder, name, seconds, quiet_at=None):
    """An m4a of noise (so it decodes like real media), with 0.2 s of silence at `quiet_at` seconds."""
    rate = 16000
    random.seed(1)
    samples = [int(random.uniform(-9000, 9000)) for _ in range(int(seconds * rate))]
    if quiet_at is not None:
        for index in range(int(quiet_at * rate), int((quiet_at + 0.2) * rate)):
            samples[index] = 0
    wav, m4a = pathlib.Path(folder, name + ".wav"), pathlib.Path(folder, name + ".m4a")
    with wave.open(str(wav), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(wav), str(m4a)], check=True, capture_output=True)
    return str(m4a)


class ManifestTests(unittest.TestCase):
    def test_entrypoint_is_executable(self):
        self.assertTrue(os.access(ENTRYPOINT, os.X_OK), f"{ENTRYPOINT} is missing or not executable (build first?)")

    def test_unknown_method_is_an_error(self):
        with tempfile.TemporaryDirectory() as folder:
            response = call(folder, "nope.nothing", {})
        self.assertIn("error", response)

    def test_reports_the_sherpa_version(self):
        out = subprocess.run([str(ENTRYPOINT), "--version"], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stdout.strip(), "1.13.8")


class CaptionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.mkdtemp()
        cls.short = make_audio(cls.folder, "clip 1", 12)
        cls.long = make_audio(cls.folder, "long", 50, quiet_at=19.5)

    def setUp(self):
        self.output = pathlib.Path(tempfile.mkdtemp(), "request")
        self.output.mkdir(mode=0o700)

    def run_request(self, media=None, options=None, **params):
        params = {"mediaPath": media or self.short, "language": "vi", "outputDirectory": str(self.output),
                  "options": options or {}, **params}
        session = Session(self.folder)
        try:
            return session.request("r1", "captions.transcribe", params, PROVIDER)
        finally:
            session.close()

    def succeed(self, **kwargs):
        lines, reply = self.run_request(**kwargs)
        self.assertNotIn("error", reply, reply)
        return lines, reply["result"]

    def cues(self, name="clip 1"):
        text = pathlib.Path(self.output, name + ".srt").read_text(encoding="utf-8")
        cues = []
        for block in text.strip().split("\n\n"):
            _, times, caption = block.split("\n", 2)
            begin, finish = times.split(" --> ")
            seconds = lambda t: int(t[:2]) * 3600 + int(t[3:5]) * 60 + int(t[6:8]) + int(t[9:]) / 1000  # noqa: E731
            cues.append((seconds(begin), seconds(finish), caption))
        return cues

    def words(self, name="clip 1"):
        return json.loads(pathlib.Path(self.output, name + ".words.json").read_text(encoding="utf-8"))

    def test_writes_both_files_in_sentence_case(self):
        lines, result = self.succeed()
        self.assertEqual(result, {"srtPath": "clip 1.srt", "wordsPath": "clip 1.words.json"})
        cues = self.cues()
        self.assertTrue(cues)
        for _, _, caption in cues:
            self.assertTrue(caption[0].isupper(), caption)
            self.assertEqual(caption[1:], caption[1:].lower())
        self.assertIn("progress", [line["type"] for line in lines])

    def test_captions_respect_the_character_limit(self):
        self.succeed(options={"maxCharacters": 20})
        self.assertTrue(all(len(caption) <= 20 for _, _, caption in self.cues()))

    def test_word_timings_line_up_with_the_captions(self):
        self.succeed()
        words, cues = self.words(), self.cues()
        self.assertEqual(len(words), sum(len(caption.split()) for _, _, caption in cues))
        self.assertEqual([w["text"] for w in words], [w for _, _, c in cues for w in c.split()])
        index = 0
        for begin, finish, caption in cues:
            for _ in caption.split():
                word = words[index]
                index += 1
                self.assertLessEqual(word["start"], word["end"])
                self.assertGreaterEqual(word["start"], begin - 0.001)
                self.assertLessEqual(word["end"], finish + 0.001)
        starts = [w["start"] for w in words]
        self.assertEqual(starts, sorted(starts))

    def test_vocabulary_restores_spelling_and_capitals(self):
        self.succeed()
        self.assertIn("buôn đôn", " ".join(c for _, _, c in self.cues()).lower())
        self.assertNotIn("Buôn Đôn", " ".join(c for _, _, c in self.cues()))
        self.succeed(options={"vocabulary": "Buôn Đôn, Hà Nội"})
        self.assertIn("Buôn Đôn", " ".join(c for _, _, c in self.cues()))

    def test_a_range_keeps_times_in_media_seconds(self):
        self.succeed(startSeconds=4, endSeconds=10)
        cues = self.cues()
        self.assertGreaterEqual(cues[0][0], 4.0)
        self.assertLessEqual(cues[-1][1], 11.0)
        self.assertGreater(cues[0][0], 4.0 - 0.001)

    def test_bad_ranges_are_rejected(self):
        for params in ({"startSeconds": 5, "endSeconds": 2}, {"startSeconds": 100}):
            _, reply = self.run_request(**params)
            self.assertIn("error", reply, params)

    def test_voice_detection_on_and_off_take_different_paths(self):
        lines, _ = self.succeed(options={"voiceDetection": True})
        self.assertTrue(any("Voice detection on" in line.get("message", "") for line in lines))
        lines, _ = self.succeed(options={"voiceDetection": False})
        self.assertTrue(any("Voice detection off: 1 windows" in line.get("message", "") for line in lines))

    def test_windows_are_cut_at_the_quietest_point(self):
        lines, _ = self.succeed(media=self.long, options={"voiceDetection": False})
        message = next(line["message"] for line in lines if "cuts at" in line.get("message", ""))
        self.assertIn("3 windows", message)
        first = float(message.split("cuts at [")[1].split(",")[0])
        self.assertAlmostEqual(first, 19.5, delta=0.15)

    def test_errors_are_reported(self):
        cases = [
            ({"mediaPath": ""}, "bad_request"),
            ({"mediaPath": "/nonexistent/clip.mp4"}, "not_found"),
            ({"language": "en"}, "bad_language"),
            ({"outputDirectory": ""}, "bad_request"),
        ]
        for params, code in cases:
            _, reply = self.run_request(**params)
            self.assertEqual(reply.get("error", {}).get("code"), code, params)

    def test_any_vietnamese_language_tag_is_accepted(self):
        for language in ("", "auto", "und", "vi-VN"):
            self.succeed(language=language)


if __name__ == "__main__":
    unittest.main()
