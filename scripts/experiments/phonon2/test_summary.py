import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('summary', pathlib.Path(__file__).with_name('summarize.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)

class SummaryTests(unittest.TestCase):
    def test_frozen_manifest_lengths_and_intents(self):
        manifest=json.loads(pathlib.Path(__file__).with_name("corpus-v2.json").read_text())
        commands=[x for x in manifest["fixtures"] if x.get("group")=="commands"]
        self.assertEqual(len(commands),28)
        self.assertEqual({x["intent_class"] for x in commands},set(range(14)))
        self.assertTrue(all(sum(x["intent_class"]==n for x in commands)==2 for n in range(14)))
        for fixture in manifest["fixtures"]:
            if fixture["id"].startswith("boundary-tail-"):
                self.assertEqual(fixture["samples"],round(float(fixture["id"].removeprefix("boundary-tail-"))*16000))

    def test_nearest_rank(self):
        self.assertEqual(summary.p95(list(range(1,21))), 19)
        self.assertEqual(summary.p95([7]), 7)

    def test_incomplete_and_duplicate_runs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'results.jsonl'
            rows=[dict(event='prepared',seconds=1)]
            for iteration in range(4):
                rows.append(dict(event='rejected_short',id='boundary-raw-0.1',iteration=iteration))
            path.write_text('\n'.join(json.dumps(x) for x in rows[:-1]))
            with self.assertRaisesRegex(AssertionError,'incomplete'):
                summary.summarize(path,['boundary-raw-0.1'])
            path.write_text('\n'.join(json.dumps(x) for x in rows+[rows[-1]]))
            with self.assertRaisesRegex(AssertionError,'duplicate'):
                summary.summarize(path,['boundary-raw-0.1'])

    def test_wer_is_weighted_by_reference_words(self):
        rows=[dict(event='prepared',seconds=1)]
        for iteration in range(4):
            for ident,words,errors in [('short',2,1),('long',8,1)]:
                rows.append(dict(event='inference',id=ident,iteration=iteration,group='commands',
                    reference_words=words,word_errors=errors,wall_ms=10,model_ms=9,
                    assembly_matches=True,assembly_text_matches=True,confidence_min=0.4,confidence_max=0.9,invalid_timings=0,token_count=2,confidence_count=2,
                    leading_space_tokens=1,punctuation_tokens=1))
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'results.jsonl'
            path.write_text('\n'.join(json.dumps(x) for x in rows))
            result=summary.summarize(path,['short','long'])
            self.assertEqual(result['groups']['commands']['wer_percent'],20)
            self.assertEqual(result['groups']['commands']['warm_changed_error_counts'],0)

if __name__=='__main__': unittest.main()
