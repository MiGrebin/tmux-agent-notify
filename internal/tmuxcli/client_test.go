package tmuxcli

import (
	"reflect"
	"testing"
)

func TestSplitStructuredFields(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "raw separator",
			input: "a" + separator + "b" + separator + "c",
			want:  []string{"a", "b", "c"},
		},
		{
			name:  "escaped separator",
			input: `a\037b\037c`,
			want:  []string{"a", "b", "c"},
		},
		{
			name:  "no separator",
			input: "abc",
			want:  []string{"abc"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got := splitStructuredFields(tc.input)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("splitStructuredFields(%q) = %#v, want %#v", tc.input, got, tc.want)
			}
		})
	}
}
