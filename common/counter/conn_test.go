package counter

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

func TestConnCounterAccumulatesAcrossReadsWritesAndConnections(t *testing.T) {
	storage := &TrafficStorage{}
	storage.UpCounter.Store(23)
	storage.DownCounter.Store(17)
	var transferred int64
	for _, payload := range [][]byte{[]byte("first-payload"), []byte("second-payload")} {
		conn, peer := net.Pipe()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		peer.SetDeadline(time.Now().Add(3 * time.Second))
		t.Cleanup(func() { conn.Close(); peer.Close() })
		counted := NewConnCounter(conn, storage)
		done := make(chan error, 1)
		go func() {
			defer peer.Close()
			if _, err := peer.Write(payload); err != nil {
				done <- err
				return
			}
			response := make([]byte, len(payload))
			_, err := io.ReadFull(peer, response)
			if err == nil && !bytes.Equal(response, payload) {
				err = fmt.Errorf("response mismatch")
			}
			done <- err
		}()
		// Fragment reads and writes so no single I/O contains the full total.
		for received := 0; received < len(payload); {
			size := min(2, len(payload)-received)
			n, err := counted.Read(make([]byte, size))
			if err != nil {
				t.Fatal(err)
			}
			received += n
		}
		for sent := 0; sent < len(payload); {
			n, err := counted.Write(payload[sent:min(sent+3, len(payload))])
			if err != nil {
				t.Fatal(err)
			}
			sent += n
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		if n, err := counted.Read(make([]byte, 1)); n != 0 || err != io.EOF {
			t.Fatalf("expected EOF, got %d, %v", n, err)
		}
		counted.Close()
		transferred += int64(len(payload))
		if up, down := storage.UpCounter.Load(), storage.DownCounter.Load(); up != 23+transferred || down != 17+transferred {
			t.Fatalf("lost accumulated traffic: up=%d down=%d, expected up=%d down=%d", up, down, 23+transferred, 17+transferred)
		}
	}
}
