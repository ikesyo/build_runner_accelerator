import 'package:json_annotation/json_annotation.dart';

part 'model_209.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model209 {
  const Model209({required this.id, required this.value});

  final int id;
  final String value;

  factory Model209.fromJson(Map<String, dynamic> json) =>
      _$Model209FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model209ToJson(this);
}
