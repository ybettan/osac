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

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	// SubnetTransitOverlapReason identifies the Subnet create error whose CIDR
	// overlaps the AgentlessNet routing /31 saved on its parent VirtualNetwork.
	SubnetTransitOverlapReason = "SUBNET_TRANSIT_OVERLAP"

	// SubnetErrorDomain is the API domain of Subnet validation errors.
	SubnetErrorDomain = "osac.private.v1.Subnets"
)

// NewSubnetTransitOverlapError builds the InvalidArgument error for an
// overlapping Subnet create. The message names only the authorized parent's
// reserved range.
func NewSubnetTransitOverlapError(subnetCIDR, transitCIDR string) error {
	message := fmt.Sprintf(
		"Subnet CIDR %s overlaps %s, which your VirtualNetwork reserves for routing. "+
			"Choose a CIDR that does not overlap that range.",
		subnetCIDR, transitCIDR,
	)
	failure, err := status.New(codes.InvalidArgument, message).WithDetails(&errdetails.ErrorInfo{
		Reason: SubnetTransitOverlapReason,
		Domain: SubnetErrorDomain,
	})
	if err != nil {
		return status.Error(codes.InvalidArgument, message)
	}
	return failure.Err()
}

// IsSubnetTransitOverlap reports whether err is the specific early Subnet
// overlap rejection, so the default-network controller can surface a final
// tenant condition instead of retrying.
func IsSubnetTransitOverlap(err error) bool {
	for _, detail := range status.Convert(err).Details() {
		if info, ok := detail.(*errdetails.ErrorInfo); ok &&
			info.GetReason() == SubnetTransitOverlapReason &&
			info.GetDomain() == SubnetErrorDomain {
			return status.Code(err) == codes.InvalidArgument
		}
	}
	return false
}
