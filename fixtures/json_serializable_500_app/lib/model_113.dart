import 'package:json_annotation/json_annotation.dart';

part 'model_113.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model113 {
  const Model113({required this.id, required this.value});

  final int id;
  final String value;

  factory Model113.fromJson(Map<String, dynamic> json) =>
      _$Model113FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model113ToJson(this);
}
