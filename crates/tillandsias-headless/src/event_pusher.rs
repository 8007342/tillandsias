pub(crate) fn push_udp_event(msg: &str) {
    if let Ok(socket) = std::net::UdpSocket::bind("127.0.0.1:0") {
        let _ = socket.send_to(msg.as_bytes(), "127.0.0.1:42421");
    }
}
