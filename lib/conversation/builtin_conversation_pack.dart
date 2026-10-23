import 'conversation_line.dart';

/// Offline fallback used when OpenSubtitles has no API key, is unavailable, or
/// the daily download quota has been reached.
///
/// These are original everyday Vietnamese exchanges rather than copied
/// subtitle lines. They are intentionally short so one shadowing take stays
/// focused and easy to review.
const List<ConversationLine> builtinConversationLines = <ConversationLine>[
  ConversationLine(
    id: 'builtin-01',
    displayText: 'Hôm nay trời đẹp quá.\nMình đi cà phê một chút nhé?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · making a simple plan',
  ),
  ConversationLine(
    id: 'builtin-02',
    displayText: 'Ừ, nhưng mà mình phải về trước bốn giờ.\nTối nay mình còn phải làm việc.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · agreeing with a time limit',
  ),
  ConversationLine(
    id: 'builtin-03',
    displayText:
        'Bạn đã ăn gì chưa?\nMình mới mua bánh mì, hay là mình chia nhau nhé.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · offering food',
  ),
  ConversationLine(
    id: 'builtin-04',
    displayText: 'Xin lỗi, cho mình hỏi đường đến chợ Bến Thành.\nĐi thẳng rồi rẽ trái ở ngã tư nhé.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · asking for directions',
  ),
  ConversationLine(
    id: 'builtin-05',
    displayText: 'Cái áo này đẹp thật.\nNhưng mà giá hơi cao, mình có thể giảm một chút không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · shopping',
  ),
  ConversationLine(
    id: 'builtin-06',
    displayText: 'Hôm qua mình xem một bộ phim hay lắm.\nBạn có muốn mình kể cho nghe không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · talking about a film',
  ),
  ConversationLine(
    id: 'builtin-07',
    displayText:
        'Mình hơi mệt nên muốn nghỉ sớm.\nBạn cứ làm tiếp, không sao đâu.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · saying you need a break',
  ),
  ConversationLine(
    id: 'builtin-08',
    displayText:
        'Cuối tuần này bạn có rảnh không?\nMình định đi Đà Lạt chơi hai ngày.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · making weekend plans',
  ),
  ConversationLine(
    id: 'builtin-09',
    displayText:
        'Bạn nói chậm lại một chút được không?\nMình chưa nghe rõ câu vừa rồi.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · asking someone to repeat',
  ),
  ConversationLine(
    id: 'builtin-10',
    displayText:
        'Mình mới chuyển đến đây ở.\nBạn có biết chỗ nào bán đồ ăn ngon không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · meeting a neighbour',
  ),
  ConversationLine(
    id: 'builtin-11',
    displayText: 'Anh ấy đến trễ hẹn hơn ba mươi phút.\nMình đã gọi cho anh ấy hai lần rồi.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · a small frustration',
  ),
  ConversationLine(
    id: 'builtin-12',
    displayText: 'Con mèo nhà mình lại trốn ở trên nóc tủ.\nMình phải dùng ghế để bắt nó xuống.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · telling a funny story',
  ),
  ConversationLine(
    id: 'builtin-13',
    displayText:
        'Bạn thấy thời tiết hôm nay thế nào?\nTrời âm u quá, chắc sắp mưa rồi.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · small talk',
  ),
  ConversationLine(
    id: 'builtin-14',
    displayText: 'Mình đang học tiếng Việt.\nBạn có thể giúp mình sửa cách phát âm không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · asking for language help',
  ),
  ConversationLine(
    id: 'builtin-15',
    displayText:
        'Tối nay mình nấu cơm ở nhà.\nBạn muốn ăn cá kho hay canh chua?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · deciding what to eat',
  ),
  ConversationLine(
    id: 'builtin-16',
    displayText: 'Mình để quên chìa khóa ở trong phòng.\nBây giờ mình phải quay lại lấy.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · a small mishap',
  ),
  ConversationLine(
    id: 'builtin-17',
    displayText:
        'Bạn có nghe thấy tiếng gì không?\nHình như có người đang gõ cửa.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · at home',
  ),
  ConversationLine(
    id: 'builtin-18',
    displayText: 'Mình thích buổi sáng hơn buổi tối.\nKhông khí yên tĩnh và mát mẻ hơn nhiều.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · sharing a preference',
  ),
  ConversationLine(
    id: 'builtin-19',
    displayText: 'Lát nữa mình ghé siêu thị.\nBạn cần mua thêm gì không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · running errands',
  ),
  ConversationLine(
    id: 'builtin-20',
    displayText: 'Cảm ơn bạn đã giúp mình hôm qua.\nKhông có bạn thì mình không làm xong kịp.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · thanking someone',
  ),
  ConversationLine(
    id: 'builtin-21',
    displayText:
        'Mình chưa quyết định sẽ đi đâu.\nCó lẽ mình sẽ ở nhà và đọc sách.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · being unsure',
  ),
  ConversationLine(
    id: 'builtin-22',
    displayText: 'Bạn thấy câu chuyện đó có thật không?\nMình nghĩ là họ chỉ đang đùa thôi.',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · reacting to news',
  ),
  ConversationLine(
    id: 'builtin-23',
    displayText: 'Mình muốn đặt một bàn cho hai người.\nKhoảng bảy giờ tối nay có được không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · booking a table',
  ),
  ConversationLine(
    id: 'builtin-24',
    displayText: 'Điện thoại của mình sắp hết pin.\nBạn có sạc dự phòng không?',
    sourceTitle: 'Everyday Vietnamese',
    sourceDetail: 'Offline pack · asking for a charger',
  ),
];
