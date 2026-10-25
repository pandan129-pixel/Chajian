import os, sys, time, json, frida

HOST = os.environ.get("DEVICE_HOST", "127.0.0.1:27042")
TARGET = sys.argv[1] if len(sys.argv) > 1 else "Runner"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/xyd-frida.log"
DURATION = float(sys.argv[3]) if len(sys.argv) > 3 else 900.0

dev = frida.get_device_manager().add_remote_device(HOST)
pid = None
for p in dev.enumerate_processes():
    if p.name == TARGET:
        pid = p.pid
        break
if pid is None:
    print("target not found", TARGET)
    sys.exit(2)

print("attach", TARGET, pid)
session = dev.attach(pid)
script = session.create_script(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "xyd-frida.bundle.js")).read())

f = open(OUT, "a", buffering=1)

def on_message(msg, data):
    if msg.get("type") == "send":
        p = msg.get("payload") or {}
        line = p.get("m", "")
        if line:
            f.write(line + "\n")
            print(line, flush=True)
    elif msg.get("type") == "error":
        line = "ERROR " + str(msg.get("description")) + " " + str(msg.get("stack"))
        f.write(line + "\n")
        print(line, flush=True)

script.on("message", on_message)
script.load()
f.write("=== attached pid=%d %s ===\n" % (pid, time.strftime("%H:%M:%S")))
print("loaded, logging to", OUT, flush=True)

t0 = time.time()
while time.time() - t0 < DURATION:
    time.sleep(2)
    if not session.is_detached:
        continue
    print("detached", flush=True)
    break
f.write("=== session end ===\n")
f.close()
try:
    session.detach()
except Exception:
    pass
