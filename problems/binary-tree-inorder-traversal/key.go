package main

// TreeNode is the standard LeetCode binary tree node.
type TreeNode struct {
	Val   int
	Left  *TreeNode
	Right *TreeNode
}

// InorderTraversalSolution returns inorder traversal values using an explicit stack.
func InorderTraversalSolution(root *TreeNode) []int {
	result := make([]int, 0)
	stack := make([]*TreeNode, 0)
	curr := root

	for curr != nil || len(stack) > 0 {
		for curr != nil {
			stack = append(stack, curr)
			curr = curr.Left
		}

		n := len(stack) - 1
		curr = stack[n]
		stack = stack[:n]

		result = append(result, curr.Val)
		curr = curr.Right
	}

	return result
}
