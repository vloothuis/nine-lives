"""Runs OpenSSH's sftp-server and passes data both ways. After LIMIT bytes from the client it either
ends the connection (mode `drop`) or stops answering (mode `hang`). Used by sftp_faults.sh."""
import os, signal, subprocess, sys, threading, time

mode, limit = sys.argv[1], int(sys.argv[2])
srv = subprocess.Popen(["/usr/libexec/sftp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

def back():
    while chunk := os.read(srv.stdout.fileno(), 65536):
        os.write(1, chunk)

threading.Thread(target=back, daemon=True).start()
seen = 0
while chunk := os.read(0, 65536):
    seen += len(chunk)
    if seen > limit:
        if mode == "drop":
            srv.kill()
            os._exit(1)
        os.kill(srv.pid, signal.SIGSTOP)  # the server stops answering
        # Stop reading too, so the client's pipe fills up. Exit when the client goes away.
        while os.getppid() != 1:
            time.sleep(0.2)
        srv.kill()
        os._exit(0)
    srv.stdin.write(chunk)
    srv.stdin.flush()
