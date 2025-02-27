import 'dart:convert';
import 'dart:io';
import 'package:typed_data/typed_data.dart' as typed;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:device_info/device_info.dart';

import '../setup/config.dart';

typedef Callback = void Function(String topic, dynamic payload);
final _cacheQueue = Map<String, Callback>(); // 缓存队列

/// MQTT-SERVICE
class _MQTTService {
  /// MQTT自身代码封装
  get _transitionState => _cacheQueue.isEmpty; // 过渡切换状态[为true才会执行订阅后的回调函数]
  MqttServerClient client;

  /*
  final String serverAddress; // 订阅地址
  final String username; // 用户名
  final String password; // 密码
  final int port; // 端口


  _MQTTService({
    this.serverAddress,
    this.username,
    this.password,
    this.port
  });
  */

  get isConnected => client.connectionStatus.state == MqttConnectionState.connected; // MQTT是否处于连接状态
  get isDisconnected => client.connectionStatus.state == MqttConnectionState.disconnected; // MQTT是否处于断开状态

  // 连接成功
  void onConnected() {
    print('MQTT-client已成功连接');
  }

  // 重新连接
  void onAutoReconnect() {
    print('MQTT-client正在重新连接');
  }

  // 重新连接成功
  void onAutoReconnected() {
    print('MQTT-client重连成功');
  }

  // 连接断开
  void onDisconnected() {
    print('MQTT-client连接断开');
  }

  // 订阅主题成功
  void onSubscribed(String topic) {
    print('订阅成功: $topic');
  }

  // 订阅主题失败
  void onSubscribeFail(String topic) {
    _cacheQueue.remove(topic);
    print('订阅失败: $topic');
  }

  // 成功取消订阅
  void onUnsubscribed(String topic) {
    _cacheQueue.remove(topic);
    print('取消订阅: $topic');
  }

  // 收到 PING 响应
  void pong() {
    print('收到心跳唤醒');
  }

  /// 业务定制功能
  // 手动连接
  Future<void> get connect async{
    print('MQTT-client正准备尝试连接');
    if (client == null) { // 未实例化才开始执行实例化
      final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin(); // 获取设备信息
      final Future<String> fetchIdentifier = // 获取设备唯一标识码
      AppConfig.platform == 'ANDROID'
          ? deviceInfoPlugin.androidInfo.then((AndroidDeviceInfo build) => build.androidId) // android
          : AppConfig.platform == 'IOS'
          ? deviceInfoPlugin.iosInfo.then((IosDeviceInfo build) => build.identifierForVendor) // ios
          : null;

      final String identifier = await fetchIdentifier; // 使用设备唯一编码作为MQTT-clientID的一部分，防止重复的ID被踢下线

      /**
       * EMQ_X测试地址
       * host: broker.emqx.io
       * client_id: flutter_client
       * port: 1883
       * */
      client = MqttServerClient.withPort('broker.emqx.io', null /* 使用MqttConnectMessage进行构造后，这里的client_id将被忽略 */, 1883)
        ..secure = false
        ..securityContext = SecurityContext.defaultContext
        ..onConnected = onConnected
        ..onAutoReconnect = onAutoReconnect
        ..onAutoReconnected = onAutoReconnected
        ..onDisconnected = onDisconnected
        ..onUnsubscribed = onUnsubscribed
        ..onSubscribed = onSubscribed
        ..onSubscribeFail = onSubscribeFail
        ..pongCallback = pong
        ..logging(on: !AppConfig.isProduction);

      client.connectionMessage = MqttConnectMessage()
        ..withClientIdentifier('${AppConfig.platform.toLowerCase()}-${identifier.toLowerCase() ?? DateTime.now().millisecondsSinceEpoch}') // client_id
        ..authenticateAs('mqtt_example', 'mqtt_example')
        ..keepAliveFor(60)
        // ..withProtocolName('MQIsdp')
        // ..withProtocolVersion(3)
        ..withWillRetain()
        ..withWillTopic('will topic')
        ..withWillMessage('will message')
        ..withWillQos(MqttQos.atLeastOnce /* MqttQos.atMostOnce */)
        ..startClean();

      await client
          .connect() // 异步函数(开始连接)
          .then((value){
        print('mqtt-client连接成功: ${value.state}');
      })
          .catchError((err){
        print('mqtt-client连接失败: $err');
        client.disconnect();
      });

      client.updates // 处理推送消息
          ?.listen((List<MqttReceivedMessage<MqttMessage>> message) { // 收到消息推送
            if (message == null) return;
            final String topic =  message[0]?.topic;
            final MqttPublishMessage _message = message[0]?.payload;

            if (topic == null || _message == null) return; // 广播数据有误需要退出
            if (_transitionState || !_cacheQueue.containsKey(topic)) return; // 本地未订阅该条数据不予处理

            final Callback callback = _cacheQueue[topic];
            // final String payload = MqttPublishPayload.bytesToStringAsString(_message.payload.message); // 使用自带的解析器会导致中文乱码，可用Utf8Decoder代替
            final String payload = Utf8Decoder().convert(_message.payload.message);
            print("收到订阅:$topic");
            print("消息推送:$payload");
            if (callback != null) callback(topic, json.decode(payload));
          });
    }
  }

  // 手动再次连接
  Future<void> get reconnect async{
    print('MQTT-client正准备尝试重连');
    if (isDisconnected) await client.connect();
  }

  // 手动关闭连接
  void get close{
    print('MQTT-client正准备尝试关闭连接');
    return client.disconnect();
  }

  // 发布订阅
  void publish(String topic, String message){
    final MqttClientPayloadBuilder builder = MqttClientPayloadBuilder();
    final _buf = typed.Uint8Buffer();

    _buf.addAll(Utf8Encoder().convert(message));
    builder.addBuffer(_buf);

    client.publishMessage(topic, MqttQos.exactlyOnce, builder.payload); // builder.payload也是可用的
  }

  // 添加订阅
  void subscribe(String topic, Callback callback){
    _cacheQueue.putIfAbsent(topic, () => callback); // TODO 插入或替换队列中的回调函数
    print('正在订阅: $topic');
    if (topic.isNotEmpty && topic != null && isConnected) {
      client.subscribe(topic, MqttQos.exactlyOnce);
    }
  }

  // 取消订阅
  void unsubscribe(String topic){
    _cacheQueue.remove(topic);
    print('正在取消订阅: $topic');
    if (topic.isNotEmpty && topic != null && isConnected) {
      client.unsubscribe(topic);
    }
  }
}

_MQTTService mqttService = _MQTTService();
