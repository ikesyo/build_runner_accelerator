import 'package:json_annotation/json_annotation.dart';

part 'model_466.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model466 {
  const Model466({required this.id, required this.value});

  final int id;
  final String value;

  factory Model466.fromJson(Map<String, dynamic> json) =>
      _$Model466FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model466ToJson(this);
}
