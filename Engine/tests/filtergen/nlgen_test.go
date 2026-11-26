package filter

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"testing"
)

func r(b bool, err error) string {
	if err != nil {
		return "err"
	}
	return fmt.Sprint(b)
}

func TestNLGen(t *testing.T) {
	in, _ := os.Open("/tmp/nl-filtergen/in.txt")
	out, _ := os.Create("/tmp/nl-filtergen/out.txt")
	w := bufio.NewWriter(out)
	sc := bufio.NewScanner(in)
	for sc.Scan() {
		f := strings.Split(sc.Text(), "\t")
		if f[0] == "M" {
			m, err := Match(f[1], f[2])
			fmt.Fprintf(w, "%s\t%s\n", sc.Text(), r(m, err))
		} else {
			ps := ParsePatterns(strings.Split(f[1], "\x1f"))
			m, err := List(ps, f[2])
			m2, c, err2 := ListWithChild(ps, f[2])
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", sc.Text(), r(m, err), r(m2, err2), r(c, err2))
		}
	}
	w.Flush()
	out.Close()
}
