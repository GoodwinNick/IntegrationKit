//
//  UIUserActivityRestoring.swift
//  IntegrationKit — Checks/Stubs/UIKitShim
//
//  Stand-in for `UIUserActivityRestoring`, compiled into a module called `UIKit`. Exists only
//  because the checks compile natively on macOS, where the real UIKit does not exist.
//  `AppsFlyerServicing.handleContinue` only ever names the type, never a member of it, so this
//  carries no requirements.
//

import Foundation

public protocol UIUserActivityRestoring: AnyObject {}
