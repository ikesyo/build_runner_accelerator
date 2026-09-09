import 'package:json_annotation/json_annotation.dart';

part 'model_02.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model02 {
  const Model02({required this.id, required this.value});

  final int id;
  final String value;

  factory Model02.fromJson(Map<String, dynamic> json) =>
      _$Model02FromJson(json);

  Map<String, dynamic> toJson() => _$Model02ToJson(this);
}
