import 'package:json_annotation/json_annotation.dart';

part 'model_078.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model078 {
  const Model078({required this.id, required this.value});

  final int id;
  final String value;

  factory Model078.fromJson(Map<String, dynamic> json) =>
      _$Model078FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model078ToJson(this);
}
