import 'package:json_annotation/json_annotation.dart';

part 'model_092.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model092 {
  const Model092({required this.id, required this.value});

  final int id;
  final String value;

  factory Model092.fromJson(Map<String, dynamic> json) =>
      _$Model092FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model092ToJson(this);
}
