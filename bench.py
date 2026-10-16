#!/usr/bin/env python3
"""Score speech-engine configurations on your own voice.

Record takes first (Diagnostics → Benchmark… in the app), then run:
    ./bench.py                 # latest session in the app's bench/ folder
    ./bench.py <session dir> --models ggml-large-v3-turbo-q5_0.bin

Every configuration (model × beam search × speech detection × vocabulary prompt) runs
on its own local whisper-server. Reports word error rate (WER, lower is better) and
latency per take, then the worst sentences for the configuration the app uses now.
"""
import argparse, json, os, re, socket, statistics, subprocess, sys, time, urllib.request, uuid

DATA = os.path.expanduser('~/Library/Application Support/BudDial')   # the app's data: config, models, bench takes
MODELS = os.path.join(DATA, 'models')
VAD = os.path.join(MODELS, 'ggml-silero-v6.2.0.bin')
SERVER = next((p for p in ('/opt/homebrew/bin/whisper-server', '/usr/local/bin/whisper-server') if os.path.exists(p)), None)
DEFAULT_VOCABULARY = 'BudDial, Homebrew, Cursor Bugbot, Codex, README, AirPods, Whisper'

def words(text):
    text = re.sub(r"[^a-z0-9' ]+", ' ', text.lower().replace('-', ' '))
    return [w.strip("'") for w in text.split() if w.strip("'")]

def word_errors(reference, hypothesis):
    r, h = words(reference), words(hypothesis)
    row = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, row = row, [i] + [0] * len(h)
        for j, hw in enumerate(h, 1):
            row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (rw != hw))
    return row[-1], len(r)

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def post(port, wav, prompt):
    boundary = uuid.uuid4().hex
    fields = [('response_format', 'json'), ('temperature', '0.0')] + ([('prompt', prompt)] if prompt else [])
    body = b''.join(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields)
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
             f'Content-Type: audio/wav\r\n\r\n').encode() + wav + f'\r\n--{boundary}--\r\n'.encode()
    request = urllib.request.Request(f'http://127.0.0.1:{port}/inference', body, {'Content-Type': f'multipart/form-data; boundary={boundary}'})
    started = time.time()
    text = json.loads(urllib.request.urlopen(request, timeout=120).read())['text']
    return ' '.join(text.split()), (time.time() - started) * 1000

def run(model, beam, vad, takes, prompt, language):
    port = free_port()
    args = [SERVER, '-m', os.path.join(MODELS, model), '--host', '127.0.0.1', '--port', str(port), '-l', language, '-nt', '-sns', '-t', '4']
    if beam > 1: args += ['-bs', str(beam)]
    if vad: args += ['--vad', '-vm', VAD]
    server = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(600):
            try: urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=1); break
            except Exception: time.sleep(.1)
        post(port, takes[0][1], None)   # warm the GPU kernels
        results = []
        for reference, wav in takes:
            text, ms = post(port, wav, prompt)
            results.append((reference, text, ms))
        return results
    finally:
        server.terminate(); server.wait()

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('session', nargs='?', help='a session directory in bench/ (default: latest)')
    parser.add_argument('--models', nargs='*', help='model files in models/ (default: all installed)')
    args = parser.parse_args()
    if not SERVER: sys.exit('whisper-server not found: brew install whisper-cpp')
    bench = os.path.join(DATA, 'bench')
    session = args.session or max((os.path.join(bench, d) for d in os.listdir(bench)), key=os.path.getmtime)
    takes = [(open(os.path.join(session, f[:-4] + '.txt')).read().strip(), open(os.path.join(session, f), 'rb').read())
             for f in sorted(os.listdir(session)) if f.endswith('.wav') and os.path.exists(os.path.join(session, f[:-4] + '.txt'))]
    if not takes: sys.exit(f'No takes in {session}')
    config = json.load(open(os.path.join(DATA, 'config.json')))
    vocabulary = config.get('vocabulary') or DEFAULT_VOCABULARY
    prompt = f'Words I use: {vocabulary.strip(" ,.")}.'
    models = args.models or sorted(f for f in os.listdir(MODELS) if f.startswith('ggml-') and f.endswith('.bin') and 'silero' not in f)
    current = (config.get('model', 'ggml-large-v3-turbo-q5_0.bin'), config.get('beamSize', 5), config.get('vad', True), True)
    print(f'{len(takes)} takes from {os.path.relpath(session, ROOT)}; vocabulary prompt: "{prompt}"\n')
    print(f'{"model":38} {"beam":>4} {"vad":>4} {"vocab":>5}  {"WER":>6}  {"median ms":>9}  {"max ms":>7}')
    table = {}
    for model in models:
        for beam in (1, 5):
            for vad in (False, True):
                for use_vocabulary in (False, True):
                    results = run(model, beam, vad, takes, prompt if use_vocabulary else None, config.get('language', 'en'))
                    errors = sum(word_errors(r, h)[0] for r, h, _ in results)
                    total = sum(word_errors(r, h)[1] for r, h, _ in results)
                    latencies = [ms for _, _, ms in results]
                    key = (model, beam, vad, use_vocabulary)
                    table[key] = results
                    mark = '  ← app now' if key == current else ''
                    print(f'{model:38} {beam:>4} {"on" if vad else "off":>4} {"on" if use_vocabulary else "off":>5}  '
                          f'{errors / total:6.1%}  {statistics.median(latencies):9.0f}  {max(latencies):7.0f}{mark}', flush=True)
    if current in table:
        print('\nWorst sentences with the app\'s current configuration:')
        for reference, text, _ in sorted(table[current], key=lambda r: -word_errors(r[0], r[1])[0] / max(1, word_errors(r[0], r[1])[1]))[:5]:
            e, n = word_errors(reference, text)
            if e: print(f'  {e}/{n} wrong\n    said:  {reference}\n    heard: {text}')

if __name__ == '__main__':
    main()
