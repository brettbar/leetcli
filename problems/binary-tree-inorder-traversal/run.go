package main

import (
	"encoding/csv"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	colorReset = "\033[0m"
	colorRed   = "\033[31m"
	colorGreen = "\033[32m"
)

func main() {
	rows, err := readTestsCSV("tests.csv")
	if err != nil {
		fmt.Fprintf(os.Stderr, "read tests.csv: %v\n", err)
		os.Exit(1)
	}

	passed := 0
	for i, row := range rows {
		nodes, err := parseTreeInput(row[1])
		if err != nil {
			fmt.Printf("case %d: parse input error: %v\n", i+1, err)
			continue
		}
		expected, err := parseIntSlice(row[2])
		if err != nil {
			fmt.Printf("case %d: parse expected error: %v\n", i+1, err)
			continue
		}

		inputRoot := buildTree(nodes)
		keyRoot := buildTree(nodes)
		gotInput := InorderTraversal(inputRoot)
		gotKey := InorderTraversalSolution(keyRoot)

		ok := equalSlices(gotInput, gotKey) && equalSlices(gotKey, expected)
		if ok {
			passed++
		}
		printCaseResult(i+1, ok, row[1], gotInput, gotKey, expected)
	}

	summaryColor := colorRed
	if passed == len(rows) {
		summaryColor = colorGreen
	}
	fmt.Printf("%spassed %d/%d%s\n", summaryColor, passed, len(rows), colorReset)
}

func readTestsCSV(path string) ([][]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	r := csv.NewReader(f)
	records, err := r.ReadAll()
	if err != nil {
		return nil, err
	}
	if len(records) <= 1 {
		return nil, fmt.Errorf("no test rows")
	}
	return records[1:], nil
}

func parseTreeInput(s string) ([]*int, error) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "root=")
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	if strings.TrimSpace(s) == "" {
		return []*int{}, nil
	}

	raw := strings.Split(s, ",")
	out := make([]*int, 0, len(raw))
	for _, v := range raw {
		t := strings.TrimSpace(v)
		if strings.EqualFold(t, "null") {
			out = append(out, nil)
			continue
		}
		n, err := strconv.Atoi(t)
		if err != nil {
			return nil, err
		}
		nCopy := n
		out = append(out, &nCopy)
	}
	return out, nil
}

func buildTree(vals []*int) *TreeNode {
	if len(vals) == 0 || vals[0] == nil {
		return nil
	}
	root := &TreeNode{Val: *vals[0]}
	queue := []*TreeNode{root}
	i := 1

	for len(queue) > 0 && i < len(vals) {
		node := queue[0]
		queue = queue[1:]

		if i < len(vals) && vals[i] != nil {
			node.Left = &TreeNode{Val: *vals[i]}
			queue = append(queue, node.Left)
		}
		i++

		if i < len(vals) && vals[i] != nil {
			node.Right = &TreeNode{Val: *vals[i]}
			queue = append(queue, node.Right)
		}
		i++
	}

	return root
}

func parseIntSlice(s string) ([]int, error) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	if strings.TrimSpace(s) == "" {
		return []int{}, nil
	}

	raw := strings.Split(s, ",")
	out := make([]int, 0, len(raw))
	for _, v := range raw {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, nil
}

func equalSlices(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func printCaseResult(caseNum int, ok bool, input string, gotInput, gotKey, expected []int) {
	statusColor := colorRed
	statusText := "FAIL"
	if ok {
		statusColor = colorGreen
		statusText = "PASS"
	}
	fmt.Printf("%s[%s] Case %d%s\n", statusColor, statusText, caseNum, colorReset)
	fmt.Printf("  input:    %s\n", input)
	fmt.Printf("  input:    %v\n", gotInput)
	fmt.Printf("  key:      %v\n", gotKey)
	fmt.Printf("  expected: %v\n\n", expected)
}
