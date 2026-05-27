import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  ProviderRegistered,
  ProviderDeregistered,
  ServiceStarted,
  ServiceStopped,
  PaymentsDestinationSet,
} from "../generated/CampDataService/CampDataService";
import { Provider, ServiceRegistration } from "../generated/schema";

export function handleProviderRegistered(event: ProviderRegistered): void {
  let provider = new Provider(event.params.provider.toHex());
  provider.endpoint    = event.params.endpoint;
  provider.geoHash     = event.params.geoHash;
  provider.registered  = true;
  provider.paymentsDestination = event.params.provider;
  provider.registeredAt = event.block.timestamp;
  provider.save();
}

export function handleProviderDeregistered(event: ProviderDeregistered): void {
  let provider = Provider.load(event.params.provider.toHex());
  if (!provider) return;
  provider.registered = false;
  provider.save();
}

export function handlePaymentsDestinationSet(event: PaymentsDestinationSet): void {
  let provider = Provider.load(event.params.provider.toHex());
  if (!provider) return;
  provider.paymentsDestination = event.params.destination;
  provider.save();
}

export function handleServiceStarted(event: ServiceStarted): void {
  let id = event.params.provider.toHex() + "-" + event.params.tier.toString();
  let reg = ServiceRegistration.load(id);

  if (!reg) {
    reg = new ServiceRegistration(id);
    reg.provider  = event.params.provider.toHex();
    reg.tier      = event.params.tier;
    reg.startedAt = event.block.timestamp;
  }

  reg.endpoint = event.params.endpoint;
  reg.active   = true;
  reg.stoppedAt = null;
  reg.save();
}

export function handleServiceStopped(event: ServiceStopped): void {
  let id = event.params.provider.toHex() + "-" + event.params.tier.toString();
  let reg = ServiceRegistration.load(id);
  if (!reg) return;
  reg.active    = false;
  reg.stoppedAt = event.block.timestamp;
  reg.save();
}
