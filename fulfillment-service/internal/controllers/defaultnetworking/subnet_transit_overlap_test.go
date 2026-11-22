/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

package defaultnetworking

import (
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var _ = Describe("Subnet transit overlap error", func() {
	It("is recognized through wrapping only for its own reason and domain", func() {
		err := NewSubnetTransitOverlapError("10.0.9.0/24", "10.0.9.0/31")
		Expect(status.Code(err)).To(Equal(codes.InvalidArgument))
		Expect(IsSubnetTransitOverlap(err)).To(BeTrue())
		Expect(IsSubnetTransitOverlap(fmt.Errorf("failed to ensure default IPv4 Subnet: %w", err))).To(BeTrue())
		Expect(IsSubnetTransitOverlap(status.Error(codes.InvalidArgument, "overlap"))).To(BeFalse())
	})
})
