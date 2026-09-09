import 'package:json_annotation/json_annotation.dart';

part 'model_259.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model259 {
  const Model259({required this.id, required this.value});

  final int id;
  final String value;

  factory Model259.fromJson(Map<String, dynamic> json) =>
      _$Model259FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model259ToJson(this);
}
