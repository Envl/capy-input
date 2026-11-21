import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static func httpMessage(status: Int) -> String {
        switch status {
        case 401, 403:
            return L10n.errorHTTPAuth(status)
        case 404:
            return L10n.errorHTTPNotFound
        case 408:
            return L10n.errorHTTPTimeout
        case 429:
            return L10n.errorHTTPRateLimited
        case 500...599:
            return L10n.errorHTTPServerUnavailable(status)
        default:
            return L10n.errorHTTPGeneric(status)
        }
    }

    static func userMessage(for error: Error) -> String {
        if let appError = error as? AppError {
            return appError.message
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return urlErrorMessage(code: nsError.code)
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return L10n.errorStorageFull
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return L10n.errorStoragePermission
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOSPC):
                return L10n.errorStorageFull
            case Int(EACCES), Int(EPERM):
                return L10n.errorStoragePermission
            case Int(ETIMEDOUT):
                return L10n.errorTimedOut
            case Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH):
                return L10n.errorNoInternet
            case Int(ECONNRESET), Int(ECONNABORTED), Int(EPIPE):
                return L10n.errorConnectionLost
            case Int(ECONNREFUSED):
                return L10n.errorCannotConnect
            default:
                break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return urlErrorMessage(code: underlying.code)
        }
        return error.localizedDescription
    }

    private static func urlErrorMessage(code: Int) -> String {
        switch code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return L10n.errorNoInternet
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorCallIsActive:
            return L10n.errorConnectionLost
        case NSURLErrorTimedOut:
            return L10n.errorTimedOut
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return L10n.errorDnsFailed
        case NSURLErrorCannotConnectToHost:
            return L10n.errorCannotConnect
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return L10n.errorSecureConnection
        case NSURLErrorBadServerResponse,
             NSURLErrorCannotParseResponse,
             NSURLErrorCannotDecodeRawData,
             NSURLErrorCannotDecodeContentData,
             NSURLErrorZeroByteResource:
            return L10n.errorInvalidResponse
        case NSURLErrorBadURL,
             NSURLErrorUnsupportedURL:
            return L10n.errorInvalidURL
        default:
            return L10n.errorNetworkCode(code)
        }
    }
}
