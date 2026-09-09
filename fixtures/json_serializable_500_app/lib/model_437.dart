import 'package:json_annotation/json_annotation.dart';

part 'model_437.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model437 {
  const Model437({required this.id, required this.value});

  final int id;
  final String value;

  factory Model437.fromJson(Map<String, dynamic> json) =>
      _$Model437FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model437ToJson(this);
}
