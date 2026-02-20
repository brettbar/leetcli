package main

// ListNode is the standard LeetCode singly-linked list node.
type ListNode struct {
	Val  int
	Next *ListNode
}

// ReverseListSolution reverses a singly linked list iteratively.
func ReverseListSolution(head *ListNode) *ListNode {
	var prev *ListNode
	curr := head
	for curr != nil {
		next := curr.Next
		curr.Next = prev
		prev = curr
		curr = next
	}
	return prev
}
