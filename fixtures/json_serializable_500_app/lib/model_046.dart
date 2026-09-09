import 'package:json_annotation/json_annotation.dart';

part 'model_046.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model046 {
  const Model046({required this.id, required this.value});

  final int id;
  final String value;

  factory Model046.fromJson(Map<String, dynamic> json) =>
      _$Model046FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model046ToJson(this);
}
